import Cocoa
import Combine

private final class OutlineItemPointerBox {
	weak var value: AnyObject?
	init(_ value: AnyObject) {
		self.value = value
	}
}

@MainActor
private final class OutlineUpdateCoalescer {
	private var scheduled = false
	private var pending: (() -> Void)?

	func schedule(after delay: TimeInterval = 0, _ block: @escaping () -> Void) {
		pending = block
		guard !scheduled else { return }
		scheduled = true
		let execute: @MainActor @Sendable () -> Void = { [weak self] in
			guard let self else { return }
			self.scheduled = false
			let work = self.pending
			self.pending = nil
			work?()
		}
		if delay <= 0 {
			DispatchQueue.main.async(execute: execute)
		} else {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
		}
	}

	func cancel() {
		pending = nil
		scheduled = false
	}
}

@MainActor
class FileTreeViewController: NSViewController, NSMenuDelegate, HoverScrollStateProvider {
	private struct OutlineSnapshot {
		let generation: Int
		let rootItems: [FileSystemItemType]
		let childrenByID: [UUID: [FileSystemItemType]]
	}
	private var dataSnapshotGeneration: Int = 0
	private var dataSnapshot: OutlineSnapshot = OutlineSnapshot(generation: 0, rootItems: [], childrenByID: [:])
	private var snapshotDebounceWorkItem: DispatchWorkItem?
	private let outlineUpdates = OutlineUpdateCoalescer()
	private var updateGeneration = UUID()
	
	var outlineView: NSOutlineView!
	private var scrollView: NSScrollView!
	
	/// Hosting window ID, used to route notifications (avoid affecting other windows).
	var windowID: Int = 0
	
	var fileManager: RepoFileManagerViewModel!
	var workspaceManager: WorkspaceManagerViewModel?
	private var cancellables = Set<AnyCancellable>()
	private var sortMethod: SortMethod = .nameAscending
	private var scrollingDebounceTimer: Timer?
	private var hoverResetWorkItem: DispatchWorkItem?
	private let hoverResetWorkGate = WorkItemGate()
	
	// Controller-level scroll state
	var isScrolling: Bool = false
	
	// Local array of root folders
	var localRoots: [FolderViewModel] = []
	
	// Subscriptions for expansions & children
	var expansionSubscriptions: [UUID: AnyCancellable] = [:]
	var childrenArraySubscriptions: [UUID: AnyCancellable] = [:]
	private var knownSubfolderIDsByParent: [UUID: Set<UUID>] = [:]
	private var folderByID: [UUID: FolderViewModel] = [:] // Fast UUID lookup to avoid repeated DFS traversals
	private var itemPtrByFolderID: [UUID: OutlineItemPointerBox] = [:]
	let expansionDepthLimit = 3

	@inline(__always)
	private func outlineItemPointer(for folder: FolderViewModel) -> AnyObject? {
		if let box = itemPtrByFolderID[folder.id] {
			if let pointer = box.value {
				return pointer
			}
			itemPtrByFolderID.removeValue(forKey: folder.id)
		}
		guard let outlineView else { return nil }
		let rowCount = outlineView.numberOfRows
		guard rowCount > 0 else { return nil }
		for row in 0..<rowCount {
			guard let item = outlineView.item(atRow: row) as? FileSystemItemType else { continue }
			if case .folder(let existing) = item, existing.id == folder.id {
				cacheOutlineItemPointer(item, for: folder.id)
				return item as AnyObject
			}
		}
		return nil
	}

	@inline(__always)
	func cacheOutlineItemPointer(_ item: Any, for folderID: UUID) {
		if let obj = item as AnyObject? {
			itemPtrByFolderID[folderID] = OutlineItemPointerBox(obj)
			processExpansionQueueIfNeeded()
			processCollapseQueueIfNeeded()
		}
	}

	private func removeCachedPointers(for folder: FolderViewModel) {
		var stack: [FolderViewModel] = [folder]
		while let node = stack.popLast() {
			itemPtrByFolderID.removeValue(forKey: node.id)
			stack.append(contentsOf: node.subfolders)
		}
	}
	
	private func removeCachedDescendantPointers(for folder: FolderViewModel) {
		var stack: [FolderViewModel] = folder.subfolders
		while let node = stack.popLast() {
			itemPtrByFolderID.removeValue(forKey: node.id)
			stack.append(contentsOf: node.subfolders)
		}
	}

	// NEW: Track which folders are expanded (to build shallow snapshots)
	private(set) var expandedFolderIDs = Set<UUID>()
	
	// Expansion gate freshness
	private var expandedGateVersion: UInt64 = 0
	private var snapshotExpandedGateVersion: UInt64 = 0
	private var pendingExpansionSyncScheduled = false
	private func scheduleExpansionSync() {
		guard !pendingExpansionSyncScheduled else { return }
		pendingExpansionSyncScheduled = true
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			self.pendingExpansionSyncScheduled = false
			self.performExpansionSyncInBackground()
		}
	}
	@inline(__always)
	private func markExpandedGateDirty() { expandedGateVersion &+= 1 }
	
	// Re-entrancy + programmatic expand guards
	var isApplyingSnapshot = false
	var wantsSnapshotAfterApply = false
	var programmaticOutlineDepth = 0
	
	// NEW: ignore the Combine sink while we're syncing from the outline
	var suppressModelExpansionEvents = 0
	
	// --- NEW CHUNK-EXPANSION PROPERTIES ---
	private var foldersToExpandQueue: [FolderViewModel] = []
	private var queuedExpansionFolderIDs = Set<UUID>()
	private var isProcessingExpansions = false
	private let expansionChunkSize = 50  // Increased for faster processing
	
	// --- NEW CHUNK-COLLAPSE PROPERTIES ---
	private var foldersToCollapseQueue: [FolderViewModel] = []
	private var queuedCollapseFolderIDs = Set<UUID>()
	
	private var isProcessingCollapses = false
	private let collapseChunkSize = 25
	
	// NEW - shift selection anchor tracking
	private var shiftSelectionAnchor: FileViewModel?
	
	// MARK: - Shift-click range selection
	
	@MainActor
	func setShiftSelectionAnchor(_ file: FileViewModel) {
		shiftSelectionAnchor = file
	}
	
	/// Select / deselect all files between the anchor and the clicked file (inclusive).
	@MainActor
	func handleShiftClick(on file: FileViewModel) {
		guard let parent = file.parentFolder else { return }
		
		// 1. No anchor yet or not in the same folder => behave like a normal click
		guard let anchor = shiftSelectionAnchor, anchor.parentFolder === parent else {
			setShiftSelectionAnchor(file)
			file.toggleIsChecked()
			return
		}
		
		// 2. Build the file list in the current sort order
		let orderedFiles: [FileViewModel] = parent.children.compactMap {
			if case .file(let f) = $0 { return f }; return nil
		}
		guard let i1 = orderedFiles.firstIndex(where: { $0.id == anchor.id }),
				let i2 = orderedFiles.firstIndex(where: { $0.id == file.id }) else {
			setShiftSelectionAnchor(file)
			file.toggleIsChecked()
			return
		}
		
		let range = i1 <= i2 ? i1...i2 : i2...i1
		let newState = !file.isChecked // use the intent of the click
		
		// 3. Flip all in one batch (no intermediate parent recomputes)
		fileManager?.performSelectionBatch {
			for idx in range {
				let f = orderedFiles[idx]
				if f.isChecked != newState {
					f.setIsChecked(newState)
				}
			}
		}
		
		// 4. Recompute tri-state once, bottom-up, for this branch.
		//    This is O(depth) and stays within the same runloop tick.
		if let fm = fileManager {
			fm.recomputeAncestorStates(startingAt: parent)
		}
		
		// Keep the original anchor for subsequent ⇧‑clicks.
	}
	
	override func loadView() {
		let view = NSView()
		view.wantsLayer = true
		view.layer?.backgroundColor = NSColor.clear.cgColor
		
		scrollView = NSScrollView()
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.drawsBackground = false
		
		outlineView = NSOutlineView()
		outlineView.style = .sourceList
		outlineView.selectionHighlightStyle = .none
		outlineView.rowSizeStyle = .default
		outlineView.usesAutomaticRowHeights = false
		// Match SearchFileTreeViewController – remove default 2-pt gap Cocoa adds
		outlineView.intercellSpacing      = NSSize(width: 0, height: 0)
		outlineView.rowHeight              = FontScalePreset.current.rowHeight
		outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		outlineView.headerView = nil
		outlineView.backgroundColor = .clear
		
		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
		//column.width = 300
		outlineView.addTableColumn(column)
		
		scrollView.documentView = outlineView
		view.addSubview(scrollView)
		
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
		])
		
		self.view = view
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		setupOutlineView()
		
		let menu = NSMenu()
		menu.delegate = self
		outlineView.menu = menu
		
		if fileManager != nil {
			setupBindings()
		}

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleToggleFileTreeCollapseAllNotification(_:)),
			name: .toggleFileTreeCollapseAll,
			object: nil
		)
		
		// Add scroll observation explicitly
		scrollView.contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(scrollViewDidScroll(_:)),
			name: NSView.boundsDidChangeNotification,
			object: scrollView.contentView
		)
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
		scrollingDebounceTimer?.invalidate()
		scrollingDebounceTimer = nil
		hoverResetWorkItem?.cancel()
		hoverResetWorkGate.cancel()
	}
	
	@objc private func scrollViewDidScroll(_ notification: Notification) {
		if !isScrolling {
			isScrolling = true
			resetVisibleHoverStates() // Optional, ensures no lingering hovers
		}
		
		scrollingDebounceTimer?.invalidate()
		scrollingDebounceTimer = Timer.scheduledTimer(
			timeInterval: 0.075,
			target: self,
			selector: #selector(handleScrollDebounceTimer(_:)),
			userInfo: nil,
			repeats: false
		)
	}
	
	@objc private func handleScrollDebounceTimer(_ timer: Timer) {
		isScrolling = false
	}
	
	func resetVisibleHoverStates() {
		let visibleRows = outlineView.rows(in: outlineView.visibleRect)
		guard visibleRows.length > 0 else { return }
		
		for row in visibleRows.location..<visibleRows.location + visibleRows.length {
			if let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
				for column in 0..<outlineView.numberOfColumns {
					if let cellView = rowView.view(atColumn: column) {
						(cellView as? FileCellView)?.resetHoverState()
						(cellView as? FolderCellView)?.resetHoverState()
						(cellView as? RootFolderCellView)?.resetHoverState()
					}
				}
			}
		}
	}
	
	@MainActor
	func scheduleHoverReset(after delay: TimeInterval = 0.08) {
		hoverResetWorkItem?.cancel()
		hoverResetWorkGate.cancel()
		hoverResetWorkItem = hoverResetWorkGate.schedule(after: delay) { [weak self] in
			self?.resetVisibleHoverStates()
		}
	}
	
	@objc private func handleToggleFileTreeCollapseAllNotification(_ notification: Notification) {
		guard let targetWindowID = notification.userInfo?["windowID"] as? Int,
			  targetWindowID == windowID else { return }
		guard let target = notification.object as AnyObject?,
			  target === fileManager else { return }
		handleToggleCollapseShortcut()
	}
	
	private func handleToggleCollapseShortcut() {
		guard let fileManager = fileManager else { return }
		let roots = fileManager.visibleRootFolders
		guard !roots.isEmpty else { return }
		let shouldCollapse = roots.contains { isFolderExpanded($0) }
		if shouldCollapse {
			collapseAllRootFolders(roots, fileManager: fileManager)
		} else {
			expandAllRootFolders(roots, fileManager: fileManager)
		}
	}
	
	private func collapseAllRootFolders(_ roots: [FolderViewModel], fileManager: RepoFileManagerViewModel) {
		for root in roots {
			dropPendingExpansionRequests(under: root)
			dropPendingCollapseRequests(under: root)  // Also clear child collapse requests
			unmarkExpandedBranchIncludingSelf(for: root)
		}
		
		suppressModelExpansionEvents += 1
		for root in roots {
			fileManager.collapseAllChildren(of: root)
		}
		suppressModelExpansionEvents -= 1
		
		requestApplySnapshot(suppressExpansionSync: true, debounce: 0)
		for root in roots {
			queueFolderForCollapse(root)
		}
		scheduleHoverReset()
		persistActiveWorkspaceTreeState()
	}

	private func expandAllRootFolders(_ roots: [FolderViewModel], fileManager: RepoFileManagerViewModel) {
		suppressModelExpansionEvents += 1
		for root in roots {
			root.setExpanded(true)
		}
		suppressModelExpansionEvents -= 1
		
		for root in roots {
			premarkExpandedBranch(for: root)
		}
		
		requestApplySnapshot(suppressExpansionSync: true, debounce: 0)
		for root in roots {
			queueFolderForExpansion(root)
		}
		scheduleHoverReset()
		persistActiveWorkspaceTreeState()
	}

	private func persistActiveWorkspaceTreeState() {
		workspaceManager?.markWorkspaceDirty()
	}
	
	func setupBindings() {
		if !isViewLoaded { return }
		
		cleanupBindings()
		sortMethod = fileManager.currentSortMethod
		
		if outlineView.dataSource == nil {
			outlineView.dataSource = self
		}
		if outlineView.delegate == nil {
			outlineView.delegate = self
		}
		
		setupFontScaleBinding()
		setupFileManagerBindings()
		
		localRoots = fileManager.visibleRootFolders
		for folder in localRoots {
			subscribeToFolder(folder)
		}
		
		// Seed expansion set (roots that should start expanded)
		expandedFolderIDs.removeAll()
		for root in localRoots where root.isExpanded || root.shouldExpandInOutline() {
			// Pre-mark roots and their already-expanded descendants before the first snapshot.
			premarkExpandedBranch(for: root)
		}
		
		// Apply the first snapshot immediately (fast path)
		requestApplySnapshot(debounce: 0)
		performExpansionSyncInBackground()
	}
	
	func cleanupBindings() {
		updateGeneration = UUID()
		outlineUpdates.cancel()
		snapshotDebounceWorkItem?.cancel()
		snapshotDebounceWorkItem = nil
		cancellables.removeAll()
		
		for folder in localRoots {
			unsubscribeFolder(folder)
		}
		
		localRoots = []
		expansionSubscriptions.removeAll()
		childrenArraySubscriptions.removeAll()
		folderByID.removeAll()
		itemPtrByFolderID.removeAll()
		foldersToExpandQueue.removeAll()
		foldersToCollapseQueue.removeAll()
		queuedExpansionFolderIDs.removeAll()
		queuedCollapseFolderIDs.removeAll()
		pendingExpansionSyncScheduled = false
	}
	
	// MARK: - OutlineView Setup
	
	private func setupOutlineView() {
		outlineView.allowsMultipleSelection = false
	}
	
	private func setupFontScaleBinding() {
		FontScaleManager.shared.$preset
			.dropFirst()
			.receive(on: DispatchQueue.main)
			.removeDuplicates()
			.sink { [weak self] preset in
				self?.applyFontPreset(preset)
			}
			.store(in: &cancellables)
	}

	private func applyFontPreset(_ preset: FontScalePreset) {
		guard isViewLoaded, let outlineView else { return }
		let rowHeight = preset.rowHeight
		if outlineView.rowHeight != rowHeight {
			outlineView.rowHeight = rowHeight
		}
		reloadVisibleRowsForFontChange()
		resetVisibleHoverStates()
	}

	private func reloadVisibleRowsForFontChange() {
		guard outlineView.numberOfRows > 0, outlineView.numberOfColumns > 0 else { return }
		let visibleRows = outlineView.rows(in: outlineView.visibleRect)
		guard visibleRows.length > 0 else { return }
		let rowIndexes = IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length))
		let columnIndexes = IndexSet(integersIn: 0..<outlineView.numberOfColumns)
		outlineView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
	}

	private func setupFileManagerBindings() {
		fileManager.folderDidFinishLoadingPublisher
			.receive(on: DispatchQueue.main)
			.sink { [weak self] folder in
				guard let self = self else { return }
				
				if self.fileManager.visibleRootFolders.contains(where: { $0.id == folder.id }) {
					if !self.localRoots.contains(where: { $0.id == folder.id }) {
						if let newIndex = self.fileManager.visibleRootFolders.firstIndex(where: { $0.id == folder.id }) {
							self.localRoots.insert(folder, at: newIndex)
							self.subscribeToFolder(folder)
						}
					}
				}
				
				// Snapshot-based reload instead of direct outline mutations
				self.scheduleSnapshotApply()
				
				// Use the chunked sync for both expansion and collapse:
				self.performExpansionSync(for: folder)
			}
			.store(in: &cancellables)
		
		fileManager.$rootFolders
			.receive(on: DispatchQueue.main)
			.sink { [weak self] newRootFolders in
				guard let self = self else { return }
				
				let old = self.localRoots
				let new = newRootFolders
				
				let oldDict = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
				let newDict = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
				
				let oldIDs = Set(oldDict.keys)
				let newIDs = Set(newDict.keys)
				
				// Determine changes
				let removedIDs = oldIDs.subtracting(newIDs)
				let addedIDs = newIDs.subtracting(oldIDs)
				
				// Unsubscribe removed roots
				for removedID in removedIDs {
					if let removedFolder = oldDict[removedID] {
						self.unsubscribeFolder(removedFolder)
					}
				}
				
				// Subscribe newly added roots
				for addedID in addedIDs {
					if let newFolder = newDict[addedID] {
						self.subscribeToFolder(newFolder)
					}
				}
				
				// Update our local mirror of roots to the new order
				self.localRoots = new
				
				// Apply a fresh snapshot instead of incremental outline operations
				self.scheduleSnapshotApply()
			}
			.store(in: &cancellables)
		
		fileManager.$currentSortMethod
			.receive(on: DispatchQueue.main)
			.sink { [weak self] method in
				// Snapshot-based reload on sort method change
				guard let self = self else { return }
				self.sortMethod = method
				self.scheduleSnapshotApply()
			}
			.store(in: &cancellables)
	}
	
	// MARK: - Folder Subscriptions
	
	func subscribeToFolder(_ folder: FolderViewModel) {
		folderByID[folder.id] = folder
		
		let expansionCancellable = folder.$isExpanded
			.receive(on: DispatchQueue.main)
			.removeDuplicates()  // Prevents firing when value doesn't change
			.sink { [weak self] expanded in
				guard let self = self else { return }
				// Ignore changes we ourselves wrote due to user clicking the triangle
				if self.suppressModelExpansionEvents > 0 { return }
				
				if expanded {
					// 1) Pre-mark the branch (folder + its already-expanded descendants)
					self.premarkExpandedBranch(for: folder)
					// 2) Snapshot now so nested expanded nodes will already have children
					self.requestApplySnapshot(debounce: 0)
					// 3) Expand this folder and replay expanded descendants
					self.queueFolderForExpansion(folder)
					// NEW: ensure previously-expanded descendants re-expand too
					self.queueExpandedDescendants(of: folder)
				} else {
					self.expandedFolderIDs.remove(folder.id)
					self.markExpandedGateDirty()
					// NEW: stop tracking expanded marks under this branch to keep
					// the shallow snapshot small & consistent after collapse
					self.unmarkExpandedDescendants(of: folder)
					self.requestApplySnapshot(debounce: 0)
					self.queueFolderForCollapse(folder)
				}
			}
		expansionSubscriptions[folder.id] = expansionCancellable
		
		// ⏲️ Debounce children array updates to prevent rapid/frequent outlineView.reloadItem calls that hang UI
		let childrenCancellable = folder.$children
			.receive(on: DispatchQueue.main)
			.debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
			.sink { [weak self] newChildren in
				guard let self = self else { return }

				// Record new set of subfolder IDs
				let newSet: Set<UUID> = Set(newChildren.compactMap {
					if case .folder(let sub) = $0 { return sub.id }
					return nil
				})
				let parentID = folder.id
				let oldSet = self.knownSubfolderIDsByParent[parentID] ?? []

				// Unsubscribe removed subfolders
				let removedIDs = oldSet.subtracting(newSet)
				for rid in removedIDs {
					if let removedFolder = self.findFolderByID(rid) {
						self.unsubscribeFolder(removedFolder)
					}
				}

				// Subscribe newly added subfolders
				for child in newChildren {
					if case .folder(let subfolder) = child, self.expansionSubscriptions[subfolder.id] == nil {
						self.subscribeToFolder(subfolder)
					}
				}

				self.knownSubfolderIDsByParent[parentID] = newSet

				// Coalesced snapshot apply
				self.scheduleSnapshotApply()
			}
		childrenArraySubscriptions[folder.id] = childrenCancellable
		
		if folder.isExpanded {
			expandedFolderIDs.insert(folder.id)
			// Don't call expand here; that's handled by the queue methods.
		}
	}
	
	func unsubscribeFolder(_ folder: FolderViewModel) {
		folderByID.removeValue(forKey: folder.id)
		expansionSubscriptions[folder.id]?.cancel()
		expansionSubscriptions.removeValue(forKey: folder.id)

		childrenArraySubscriptions[folder.id]?.cancel()
		childrenArraySubscriptions.removeValue(forKey: folder.id)

		knownSubfolderIDsByParent.removeValue(forKey: folder.id)
		itemPtrByFolderID.removeValue(forKey: folder.id)
		queuedExpansionFolderIDs.remove(folder.id)
		queuedCollapseFolderIDs.remove(folder.id)
		foldersToExpandQueue.removeAll { $0.id == folder.id }
		foldersToCollapseQueue.removeAll { $0.id == folder.id }

		for sub in folder.subfolders {
			unsubscribeFolder(sub)
		}
	}
	
	/// Determines whether our expansion gate currently considers this folder expanded.
	private func isFolderExpanded(_ folder: FolderViewModel) -> Bool {
		return expandedFolderIDs.contains(folder.id)
	}
	
	@inline(__always)
	private func performWithoutAnimation(_ body: () -> Void) {
		NSAnimationContext.beginGrouping()
		NSAnimationContext.current.duration = 0
		NSAnimationContext.current.allowsImplicitAnimation = false
		body()
		NSAnimationContext.endGrouping()
	}
	
	// MARK: - Chunked Expansion Methods
	
	private func enqueueFolderForExpansion(_ folder: FolderViewModel) {
		if queuedExpansionFolderIDs.insert(folder.id).inserted {
			foldersToExpandQueue.append(folder)
		}
	}
	
	private func enqueueFolderForCollapse(_ folder: FolderViewModel) {
		if queuedCollapseFolderIDs.insert(folder.id).inserted {
			foldersToCollapseQueue.append(folder)
		}
	}
	
	private func dequeueFolderFromExpansionQueue(_ folderID: UUID) {
		if let index = foldersToExpandQueue.firstIndex(where: { $0.id == folderID }) {
			foldersToExpandQueue.remove(at: index)
		}
	}
	
	private func dequeueFolderFromCollapseQueue(_ folderID: UUID) {
		if let index = foldersToCollapseQueue.firstIndex(where: { $0.id == folderID }) {
			foldersToCollapseQueue.remove(at: index)
		}
	}
	
	func queueFolderForExpansion(_ folder: FolderViewModel) {
		guard folder.shouldExpandInOutline() else { return }

		if let parent = folder.parent, !expandedFolderIDs.contains(parent.id) {
			enqueueFolderForExpansion(folder)
			processExpansionQueueIfNeeded()
			return
		}

		if let itemObj = outlineItemPointer(for: folder) {
			queuedExpansionFolderIDs.remove(folder.id)
			dequeueFolderFromExpansionQueue(folder.id)
			suppressModelExpansionEvents += 1
			programmaticOutlineDepth += 1
			performWithoutAnimation {
				outlineView.expandItem(itemObj, expandChildren: false)
			}
			programmaticOutlineDepth -= 1
			suppressModelExpansionEvents -= 1
			scheduleHoverReset()
		} else {
			enqueueFolderForExpansion(folder)
			processExpansionQueueIfNeeded()
		}
	}
	
	private func processExpansionQueueIfNeeded() {
		if !isProcessingExpansions && !foldersToExpandQueue.isEmpty {
			isProcessingExpansions = true
			DispatchQueue.main.async { [weak self] in
				self?.processNextExpansionBatch()
			}
		}
	}
	
	private func processNextExpansionBatch() {
		guard !foldersToExpandQueue.isEmpty else {
			isProcessingExpansions = false
			return
		}
		
		let batch = Array(foldersToExpandQueue.prefix(expansionChunkSize))
		var deferred: [FolderViewModel] = []
		var madeProgress = false
		
		suppressModelExpansionEvents += 1
		outlineView.beginUpdates()
		programmaticOutlineDepth += 1
		let prevScrolling = isScrolling
		isScrolling = true
		defer {
			programmaticOutlineDepth -= 1
			outlineView.endUpdates()
			suppressModelExpansionEvents -= 1
			isScrolling = prevScrolling
		}
		
		for folder in batch {
			guard folder.shouldExpandInOutline() else { continue }
			guard let itemObj = outlineItemPointer(for: folder) else {
				deferred.append(folder)
				continue
			}
			if let parent = folder.parent, !expandedFolderIDs.contains(parent.id) {
				deferred.append(folder)
				continue
			}
			performWithoutAnimation {
				outlineView.expandItem(itemObj, expandChildren: false)
			}
			madeProgress = true
		}
		
		let removeCount = min(expansionChunkSize, foldersToExpandQueue.count)
		for _ in 0..<removeCount {
			let removed = foldersToExpandQueue.removeFirst()
			queuedExpansionFolderIDs.remove(removed.id)
		}
		
		if !deferred.isEmpty {
			for f in deferred {
				enqueueFolderForExpansion(f)
			}
		}
		
		if !foldersToExpandQueue.isEmpty {
			isProcessingExpansions = false
			if madeProgress {
				processExpansionQueueIfNeeded()
			} else {
				let delay: TimeInterval = 0.06
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
					self?.processExpansionQueueIfNeeded()
				}
			}
		} else {
			isProcessingExpansions = false
		}
		
		scheduleHoverReset()
	}
	
	// MARK: - Chunked Collapse Methods
	
	func queueFolderForCollapse(_ folder: FolderViewModel) {
		// OPTIMIZATION: Skip folders whose ancestors are collapsed.
		// If a parent is collapsed, this folder cannot have a visible row,
		// so there's no point scanning for it or queueing it.
		if !hasVisibleAncestorChain(folder) {
			// Clean up any existing queue entry
			queuedCollapseFolderIDs.remove(folder.id)
			dequeueFolderFromCollapseQueue(folder.id)
			return
		}
		
		if let itemObj = outlineItemPointer(for: folder) {
			guard outlineView.isItemExpanded(itemObj) else { return }
			queuedCollapseFolderIDs.remove(folder.id)
			dequeueFolderFromCollapseQueue(folder.id)
			suppressModelExpansionEvents += 1
			programmaticOutlineDepth += 1
			performWithoutAnimation {
				outlineView.collapseItem(itemObj, collapseChildren: true)
			}
			programmaticOutlineDepth -= 1
			suppressModelExpansionEvents -= 1
			removeCachedPointers(for: folder)
			scheduleHoverReset()
		} else {
			enqueueFolderForCollapse(folder)
			processCollapseQueueIfNeeded()
		}
	}
	
	private func processCollapseQueueIfNeeded() {
		if !isProcessingCollapses && !foldersToCollapseQueue.isEmpty {
			isProcessingCollapses = true
			DispatchQueue.main.async { [weak self] in
				self?.processNextCollapseBatch()
			}
		}
	}
	
	private func processNextCollapseBatch() {
		guard !foldersToCollapseQueue.isEmpty else {
			isProcessingCollapses = false
			return
		}
		
		let batch = Array(foldersToCollapseQueue.prefix(collapseChunkSize))
		var deferred: [FolderViewModel] = []
		var madeProgress = false
		
		suppressModelExpansionEvents += 1
		outlineView.beginUpdates()
		programmaticOutlineDepth += 1
		let prevScrolling = isScrolling
		isScrolling = true
		defer {
			programmaticOutlineDepth -= 1
			outlineView.endUpdates()
			suppressModelExpansionEvents -= 1
			isScrolling = prevScrolling
		}
		
		for folder in batch {
			// OPTIMIZATION: Skip folders whose ancestors are collapsed.
			// These can never have a visible row, so don't waste time scanning.
			if !hasVisibleAncestorChain(folder) {
				// Don't defer - just drop this impossible work
				continue
			}
			
			guard let itemObj = outlineItemPointer(for: folder) else {
				// Ancestor chain is visible but no pointer yet - defer for later
				deferred.append(folder)
				continue
			}
			if outlineView.isItemExpanded(itemObj) {
				performWithoutAnimation {
					outlineView.collapseItem(itemObj, collapseChildren: true)
				}
				removeCachedPointers(for: folder)
				madeProgress = true
			}
		}
		
		let removeCount = min(collapseChunkSize, foldersToCollapseQueue.count)
		for _ in 0..<removeCount {
			let removed = foldersToCollapseQueue.removeFirst()
			queuedCollapseFolderIDs.remove(removed.id)
		}
		
		if !deferred.isEmpty {
			for folder in deferred {
				enqueueFolderForCollapse(folder)
			}
		}
		
		if !foldersToCollapseQueue.isEmpty {
			isProcessingCollapses = false
			if madeProgress {
				processCollapseQueueIfNeeded()
			} else {
				let delay: TimeInterval = 0.06
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
					self?.processCollapseQueueIfNeeded()
				}
			}
		} else {
			isProcessingCollapses = false
		}
		
		scheduleHoverReset()
	}
	
	// MARK: - Expansion Sync Methods
	
	private func performExpansionSync(for rootFolder: FolderViewModel) {
		// Lightweight nudge only: schedule expansion/collapse of the root folder on main.
		// Subtree expansion will be driven by per-folder subscriptions as children arrive.
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			if rootFolder.isExpanded {
				self.queueFolderForExpansion(rootFolder)
			} else {
				self.queueFolderForCollapse(rootFolder)
			}
		}
	}
	
	/// Called instead of the old `synchronizeExpandedState()`.
	/// This scans your folder structure along expanded paths only (parents → children),
	/// and queues expansions in that order. Collapses for non-expanded roots are applied;
	/// non-expanded descendants remain collapsed by default.
	func performExpansionSyncInBackground() {
		let rootFoldersSnapshot = localRoots
		
		// Queue roots accordingly, and seed BFS with expanded roots
		var bfsQueue: [FolderViewModel] = []
		for root in rootFoldersSnapshot {
			if root.shouldExpandInOutline() {
				queueFolderForExpansion(root)
				bfsQueue.append(root)
			} else {
				queueFolderForCollapse(root)
			}
		}
		
		// Traverse only expanded subtrees to minimize work on large repos
		while !bfsQueue.isEmpty {
			let current = bfsQueue.removeFirst()
			
			// Use subfolders list to avoid mapping all children
			for sub in current.subfolders {
				if sub.shouldExpandInOutline() {
					queueFolderForExpansion(sub)
					bfsQueue.append(sub)
				}
			}
		}
	}
}

// MARK: - Snapshot Management
extension FileTreeViewController {
	@MainActor
	private func prepareFolderChildrenForSnapshot(_ folder: FolderViewModel, sortMethod method: SortMethod) {
		folder.sortChildrenIfNeeded(
			method,
			recomputeCheckbox: false,
			recursion: .depth(0)
		)
	}

	@MainActor
	private func buildSnapshot() -> OutlineSnapshot {
		let snapshotSortMethod = fileManager?.currentSortMethod ?? sortMethod
		sortMethod = snapshotSortMethod
		let nextGen = dataSnapshotGeneration + 1
		var childrenMap: [UUID: [FileSystemItemType]] = [:]
		
		func capture(folder: FolderViewModel) {
			// Only capture children for roots and expanded folders
			let shouldCaptureChildren = (folder.parent == nil) || expandedFolderIDs.contains(folder.id)
			guard shouldCaptureChildren else { return }
			
			prepareFolderChildrenForSnapshot(folder, sortMethod: snapshotSortMethod)
			let children = folder.children
			childrenMap[folder.id] = children
			// Only recurse down expanded branches
			for child in children {
				if case .folder(let sub) = child {
					capture(folder: sub)
				}
			}
		}
		
		let roots: [FileSystemItemType] = localRoots.map { .folder($0) }
		for root in localRoots {
			capture(folder: root)
		}
		
		return OutlineSnapshot(
			generation: nextGen,
			rootItems: roots,
			childrenByID: childrenMap
		)
	}
	
	private func scheduleSnapshotApply(debounce: TimeInterval = 0.05) {
		requestApplySnapshot(debounce: debounce)
	}

	@MainActor
	private func requestApplySnapshot(suppressExpansionSync: Bool = false, debounce: TimeInterval = 0.05) {
		let generation = updateGeneration
		outlineUpdates.schedule(after: debounce) { [weak self] in
			guard let self else { return }
			guard self.updateGeneration == generation else { return }
			guard self.isViewLoaded else { return }
			if self.view.window == nil {
				self.requestApplySnapshot(suppressExpansionSync: suppressExpansionSync, debounce: 0.05)
				return
			}
			self.applyNewSnapshot(suppressExpansionSync: suppressExpansionSync)
		}
	}
	
	@MainActor
	func applyNewSnapshot(suppressExpansionSync: Bool = false) {
		// Re-entrancy guard: coalesce a follow-up apply
		if isApplyingSnapshot {
			wantsSnapshotAfterApply = true
			return
		}
		isApplyingSnapshot = true
		defer {
			isApplyingSnapshot = false
			if wantsSnapshotAfterApply {
				wantsSnapshotAfterApply = false
				// next runloop tick to avoid re-entering AppKit callbacks
				DispatchQueue.main.async { [weak self] in
					self?.applyNewSnapshot(suppressExpansionSync: suppressExpansionSync)
				}
			}
		}
		
		let newSnapshot = buildSnapshot()
		let oldSnapshot = dataSnapshot
		let gateChanged = (expandedGateVersion != snapshotExpandedGateVersion)
		
		guard let outlineView = outlineView else { return }
		
		// FAST PATH: first draw – adopt the new snapshot and reload
		if oldSnapshot.rootItems.isEmpty {
			dataSnapshotGeneration = newSnapshot.generation
			dataSnapshot = newSnapshot
			snapshotExpandedGateVersion = expandedGateVersion
			itemPtrByFolderID.removeAll()
			outlineView.reloadData()
			if !suppressExpansionSync && (gateChanged || !foldersToExpandQueue.isEmpty) {
				scheduleExpansionSync()
			}
			scheduleHoverReset()
			return
		}
		
		// Handle root changes (adds/removes/reorders) with a full reload outside of beginUpdates
		// Incremental updates for root churn are fragile with NSOutlineView + Swift value types
		let oldRootIDs = oldSnapshot.rootItems.map(\.id)
		let newRootIDs = newSnapshot.rootItems.map(\.id)
		let oldRootIDSet = Set(oldRootIDs)
		let newRootIDSet = Set(newRootIDs)
		
		// Full reload if roots were added/removed OR reordered
		if oldRootIDSet != newRootIDSet || oldRootIDs != newRootIDs {
			dataSnapshotGeneration = newSnapshot.generation
			dataSnapshot = newSnapshot
			snapshotExpandedGateVersion = expandedGateVersion
			
			// Reset caches that can reference old bridged outline items
			itemPtrByFolderID.removeAll()
			queuedExpansionFolderIDs.removeAll()
			foldersToExpandQueue.removeAll()
			queuedCollapseFolderIDs.removeAll()
			foldersToCollapseQueue.removeAll()
			
			outlineView.reloadData()
			if !suppressExpansionSync {
				scheduleExpansionSync()
			}
			scheduleHoverReset()
			return
		}
		
		// ✓ Do NOT bail if the expansion gate changed
		
		outlineView.beginUpdates()
		applyDifferences(from: oldSnapshot, to: newSnapshot, in: outlineView, suppressExpansionSync: suppressExpansionSync)
		outlineView.endUpdates()
		
		if !suppressExpansionSync && (gateChanged || !foldersToExpandQueue.isEmpty) {
			scheduleExpansionSync()
		}
		
		scheduleHoverReset()
	}
	
	/// Apply differences between two immutable snapshots to the outline view.
	///
	/// Two-phase logic:
	///  1) Removals with the OLD snapshot active (so indices are valid)
	///  2) Swap to NEW snapshot
	///  3) Reload branches that need it and apply insertions
	private func applyDifferences(from old: OutlineSnapshot,
									to new: OutlineSnapshot,
									in outlineView: NSOutlineView,
									suppressExpansionSync: Bool) {

		// --- Collect diffs ---

		// Root-level inserts/removes (moves handled elsewhere)
		let (rootRemoved, rootInserted) = diffIndices(old: old.rootItems, new: new.rootItems)

		// Per-folder diffs
		let oldParents = Set(old.childrenByID.keys)
		let newParents = Set(new.childrenByID.keys)
		let allParents = oldParents.union(newParents)
		
		// If you track children versions:
		// let candidatesByVersion = allParents.filter { (childrenVersionByID[$0] ?? 0) != (snapshotChildrenVersionByID[$0] ?? 0) }
		// Final set to examine:
		// let parentsToConsider: Set<UUID> = Set(candidatesByVersion).union(parentsDelta)
		// For now, we examine all parents since no version filtering is implemented

		// Keep these keyed by parent folder UUID (for stable matching)
		var perParentRemoved: [UUID: [Int]] = [:]
		var perParentInserted: [UUID: [Int]] = [:]
		var parentsToReload: [FolderViewModel] = []

		for folderID in allParents {
			let oldChildren = old.childrenByID[folderID] ?? []
			let newChildren = new.childrenByID[folderID] ?? []

			// Resolve the actual item instance currently held by NSOutlineView.
			// Fresh FileSystemItemType values may compare equal but can be unreliable for row/reload APIs.
			guard let parentFolder = folderForFolderID(folderID),
				let parentItem = outlineItemPointer(for: parentFolder)
			else { continue }

			// Only apply diffs to visible+expanded parents
			let isVisible = outlineView.row(forItem: parentItem) >= 0
			let isExpanded = outlineView.isItemExpanded(parentItem)
			guard isVisible && isExpanded else { continue }

			let oldIDs = oldChildren.map(\.id)
			let newIDs = newChildren.map(\.id)

			if oldIDs == newIDs {
				if oldChildren != newChildren {
					parentsToReload.append(parentFolder)
				}
				continue
			}

			if Set(oldIDs) == Set(newIDs) {
				// Same children in a different order; reload the branch so AppKit rows match the snapshot.
				parentsToReload.append(parentFolder)
				continue
			}

			let (removed, inserted) = diffIndices(old: oldChildren, new: newChildren)

			// If changes are large, prefer a reload of this branch
			if (removed.count + inserted.count) > 64 {
				parentsToReload.append(parentFolder)
				continue
			}

			perParentRemoved[folderID] = removed
			perParentInserted[folderID] = inserted
		}

		// --- Phase 1: apply removals with OLD snapshot active ---

		if !rootRemoved.isEmpty {
			let oldRoots = old.rootItems
			for idx in rootRemoved where idx < oldRoots.count {
				if case .folder(let removedFolder) = oldRoots[idx] {
					removeCachedPointers(for: removedFolder)
				}
			}
			// Remove from roots (descending order)
			let idxSet = safeIndexSet(rootRemoved.sorted(by: >), forParent: nil, isInsertion: false)
			if !idxSet.isEmpty {
				outlineView.removeItems(at: idxSet, inParent: nil, withAnimation: [])
			}
		}

		for (folderID, removed) in perParentRemoved {
			let oldChildren = old.childrenByID[folderID] ?? []
			for idx in removed where idx < oldChildren.count {
				if case .folder(let removedFolder) = oldChildren[idx] {
					removeCachedPointers(for: removedFolder)
				}
			}
			guard let parentFolder = folderForFolderID(folderID),
				let parentItem = outlineItemPointer(for: parentFolder)
			else { continue }
			let idxSet = safeIndexSet(removed.sorted(by: >), forParent: .folder(parentFolder), isInsertion: false)
			if idxSet.isEmpty {
				// If our indices don't reconcile, fallback to a branch reload later
				parentsToReload.append(parentFolder)
				continue
			}
			outlineView.removeItems(at: idxSet, inParent: parentItem, withAnimation: [])
		}

		// --- Snapshot swap: new data becomes active for reloads and insertions ---
		
		dataSnapshotGeneration = new.generation
		dataSnapshot = new
		snapshotExpandedGateVersion = expandedGateVersion

		// --- Reload branches that need it (order-only changes or large diffs) ---

		// Deduplicate parentsToReload
		var seenReloadParents = Set<UUID>()
		for folder in parentsToReload {
			guard seenReloadParents.insert(folder.id).inserted else { continue }
			guard let parentItem = outlineItemPointer(for: folder) else { continue }
			// Keep the parent's pointer; reloading children will rebuild their cells.
			removeCachedDescendantPointers(for: folder)
			outlineView.reloadItem(parentItem, reloadChildren: true)
		}

		// --- Phase 2: apply insertions with NEW snapshot active ---

		if !rootInserted.isEmpty {
			let idxSet = safeIndexSet(rootInserted.sorted(), forParent: nil, isInsertion: true)
			if !idxSet.isEmpty {
				outlineView.insertItems(at: idxSet, inParent: nil, withAnimation: [])
			}
		}

		for (folderID, inserted) in perParentInserted {
			guard let parentFolder = folderForFolderID(folderID),
				let parentItem = outlineItemPointer(for: parentFolder)
			else { continue }

			// If we already reloaded this parent, skip explicit inserts
			if seenReloadParents.contains(parentFolder.id) { continue }

			let idxSet = safeIndexSet(inserted.sorted(), forParent: .folder(parentFolder), isInsertion: true)
			if !idxSet.isEmpty {
				outlineView.insertItems(at: idxSet, inParent: parentItem, withAnimation: [])
			}
		}

	}
	
	/// Helper that computes a safe index set against the *current* dataSnapshot.
	/// For insertions, allow index == count (append). For removals, require index < count.
	private func safeIndexSet(_ indices: [Int],
	                          forParent parent: FileSystemItemType?,
	                          isInsertion: Bool) -> IndexSet {
		let count: Int = {
			if let parent = parent {
				switch parent {
				case .folder(let folder):
					return snapshotChildren(of: folder).count
				case .file:
					return 0
				}
			} else {
				return snapshotRootItems().count
			}
		}()
		
		let filtered: [Int] = indices.filter { idx in
			if isInsertion {
				return idx >= 0 && idx <= count
			} else {
				return idx >= 0 && idx < count
			}
		}
		return IndexSet(filtered)
	}
	
	/// Compute indices to remove from `old` and insert into `new`, based on identity.
	private func diffIndices(old: [FileSystemItemType],
	                         new: [FileSystemItemType]) -> (removed: [Int], inserted: [Int]) {
		let oldIDs = old.map(\.id)
		let newIDs = new.map(\.id)
		let oldSet = Set(oldIDs)
		let newSet = Set(newIDs)
		
		var removed: [Int] = []
		var inserted: [Int] = []
		
		for (idx, oid) in oldIDs.enumerated() where !newSet.contains(oid) {
			removed.append(idx)
		}
		for (idx, nid) in newIDs.enumerated() where !oldSet.contains(nid) {
			inserted.append(idx)
		}
		return (removed, inserted)
	}
	
	/// Resolve a folder model for a given folder UUID.
	private func folderForFolderID(_ id: UUID) -> FolderViewModel? {
		if let cached = folderByID[id] {
			return cached
		}
		if let located = findFolderByID(id) {
			folderByID[id] = located
			return located
		}
		return nil
	}
	
	/// Locate a folder by UUID using an indexed fast path, falling back to a BFS scan when needed.
	private func findFolderByID(_ id: UUID) -> FolderViewModel? {
		if let cached = folderByID[id] {
			return cached
		}
		for root in localRoots {
			if let hit = findFolderByID(id, startingAt: root) {
				folderByID[id] = hit
				return hit
			}
		}
		return nil
	}
	
	/// Non-recursive search that avoids deep call stacks on large trees.
	private func findFolderByID(_ id: UUID, startingAt folder: FolderViewModel) -> FolderViewModel? {
		var queue: [FolderViewModel] = [folder]
		var idx = 0
		var seen = Set<UUID>()
		while idx < queue.count {
			let node = queue[idx]
			idx += 1
			if !seen.insert(node.id).inserted { continue }
			if node.id == id { return node }
			queue.append(contentsOf: node.subfolders)
		}
		return nil
	}
}

extension FileTreeViewController {
	#if DEBUG
	@MainActor
	func _setSnapshotSortMethodForTesting(_ method: SortMethod) {
		sortMethod = method
	}
	#endif

	@MainActor
	func snapshotRootItems() -> [FileSystemItemType] {
		return dataSnapshot.rootItems
	}
	
	@MainActor
	func snapshotChildren(of folder: FolderViewModel) -> [FileSystemItemType] {
		return dataSnapshot.childrenByID[folder.id] ?? []
	}
}

// MARK: - Expanded branch helpers (targeted replay)
extension FileTreeViewController {
	/// Pre-mark this folder and any descendants that are already expanded (or should be)
	/// so `applyNewSnapshot()` will include their children immediately.
	func premarkExpandedBranch(for folder: FolderViewModel) {
		expandedFolderIDs.insert(folder.id)
		var stack: [FolderViewModel] = [folder]
		var seen = Set<UUID>()
		while let node = stack.popLast() {
			guard seen.insert(node.id).inserted else { continue }
			for sub in node.subfolders {
				if sub.isExpanded || sub.shouldExpandInOutline() {
					expandedFolderIDs.insert(sub.id)
					stack.append(sub)
				}
			}
		}
		markExpandedGateDirty()
	}
	
	/// Queues expansions for all descendants that are already marked expanded
	/// (or should be expanded) so re-expanding a parent restores the whole branch.
	func queueExpandedDescendants(of folder: FolderViewModel) {
		// BFS along expanded paths only to keep it cheap on large trees
		var queue: [FolderViewModel] = []
		// seed with direct children that are expanded
		for sub in folder.subfolders {
			if sub.isExpanded || sub.shouldExpandInOutline() {
				expandedFolderIDs.insert(sub.id)
				queueFolderForExpansion(sub)
				queue.append(sub)
			}
		}
		var idx = 0
		while idx < queue.count {
			let current = queue[idx]
			idx += 1
			for sub in current.subfolders {
				if sub.isExpanded || sub.shouldExpandInOutline() {
					expandedFolderIDs.insert(sub.id)
					queueFolderForExpansion(sub)
					queue.append(sub)
				}
			}
		}
		markExpandedGateDirty()
		// No immediate UI ops here beyond queueing; the expand queue will defer
		// items until rows exist and parents are expanded.
	}
	
	/// Removes expanded marks for all descendants of the given folder so our
	/// shallow snapshot stops recursing into collapsed branches.
	func unmarkExpandedDescendants(of folder: FolderViewModel) {
		var stack: [FolderViewModel] = folder.subfolders
		while let node = stack.popLast() {
			expandedFolderIDs.remove(node.id)
			stack.append(contentsOf: node.subfolders)
		}
		markExpandedGateDirty()
	}
}

// MARK: - Expanded branch helpers (targeted replay)
extension FileTreeViewController {
	/// Mark this folder and *all* of its descendants as expanded in the snapshot gate.
	/// Unlike `premarkExpandedBranch`, this does not consult `isExpanded/shouldExpandInOutline`.
	func markExpandedBranchRecursively(for folder: FolderViewModel, maxDepth: Int = .max) {
		var stack: [(FolderViewModel, Int)] = [(folder, 0)]
		var seen = Set<UUID>()
		while let (node, depth) = stack.popLast() {
			guard seen.insert(node.id).inserted else { continue }
			expandedFolderIDs.insert(node.id)
			if depth < maxDepth {
				let nextDepth = depth + 1
				for sub in node.subfolders {
					stack.append((sub, nextDepth))
				}
			}
		}
		markExpandedGateDirty()
	}
	
	/// Remove this folder and *all* of its descendants from the snapshot gate.
	func unmarkExpandedBranchIncludingSelf(for folder: FolderViewModel) {
		var stack: [FolderViewModel] = [folder]
		while let node = stack.popLast() {
			expandedFolderIDs.remove(node.id)
			stack.append(contentsOf: node.subfolders)
		}
		markExpandedGateDirty()
	}
	
	/// Returns true if `node` lies under `ancestor` (or is equal to ancestor).
	private func isDescendant(_ node: FolderViewModel, of ancestor: FolderViewModel) -> Bool {
		if node.id == ancestor.id { return true }
		var cur = node.parent
		while let p = cur {
			if p.id == ancestor.id { return true }
			cur = p.parent
		}
		return false
	}
	
	/// Purge any queued auto-expansion requests that target `ancestor` or its subtree.
	func dropPendingExpansionRequests(under ancestor: FolderViewModel) {
		foldersToExpandQueue.removeAll {
			let shouldDrop = isDescendant($0, of: ancestor)
			if shouldDrop {
				queuedExpansionFolderIDs.remove($0.id)
			}
			return shouldDrop
		}
	}
	
	/// (Optional) Purge queued collapses under a branch – useful if needed.
	func dropPendingCollapseRequests(under ancestor: FolderViewModel) {
		foldersToCollapseQueue.removeAll {
			let shouldDrop = isDescendant($0, of: ancestor)
			if shouldDrop {
				queuedCollapseFolderIDs.remove($0.id)
			}
			return shouldDrop
		}
	}
	
	/// Check if a folder's ancestor chain to root is fully expanded.
	/// Returns true if the folder can have a visible outline row (all ancestors are expanded).
	/// Returns false if any ancestor is collapsed, meaning this folder cannot be visible.
	@inline(__always)
	private func hasVisibleAncestorChain(_ folder: FolderViewModel) -> Bool {
		// Root folders are always potentially visible
		guard let parent = folder.parent else { return true }
		
		// Walk up the chain - all ancestors must be in expandedFolderIDs
		var current: FolderViewModel? = parent
		while let ancestor = current {
			if !expandedFolderIDs.contains(ancestor.id) {
				return false
			}
			current = ancestor.parent
		}
		return true
	}
}
