import Cocoa
import Combine

/// A very early stub of the native AppKit controller that will back the
/// search results OutlineView.  It purposely mirrors the structure of
/// `FileTreeViewController` but with *Search* specific types.  Behaviour
/// will be added gradually in follow-up commits.
@MainActor
class SearchFileTreeViewController: NSViewController,
                                    NSOutlineViewDataSource,
                                    NSOutlineViewDelegate,
									NSMenuDelegate,
                                    HoverScrollStateProvider {

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

    // MARK: - Public API -----------------------------------------------------

    weak var searchViewModel: SearchFileTreeViewModel? {
        didSet {     // Re-wire when a new VM is assigned
            setupBindings()
        }
    }

    /// Reloads the underlying outline view; callable from outside this file.
    /// Defers work to the next runloop tick to avoid re-entrant layout issues
    /// when called during SwiftUI/AppKit constraint passes.
    @MainActor
    func reloadData() {
        guard isViewLoaded else { return }
        scheduleSnapshotApply(debounce: 0)
    }

    // MARK: - Private --------------------------------------------------------

    var isScrolling: Bool = false
    fileprivate var outlineView: NSOutlineView!
    private var scrollView : NSScrollView!
    private var cancellables = Set<AnyCancellable>()
    private var scrollingDebounceTimer: Timer?

	// Snapshot-based data source state
	private struct OutlineSnapshot {
		let generation: Int
		let rootItems: [SearchItemType]
		let childrenByID: [UUID: [SearchItemType]]
	}

	private var dataSnapshotGeneration: Int = 0
	private var dataSnapshot: OutlineSnapshot = OutlineSnapshot(generation: 0, rootItems: [], childrenByID: [:])
	private var snapshotDebounceWorkItem: DispatchWorkItem?
	private var snapshotApplyTask: Task<Void, Never>?
	private let outlineUpdates = OutlineUpdateCoalescer()
	private var updateGeneration = UUID()

	// --- CHUNKED-EXPANSION PROPERTIES ------------------------------------
	private var foldersToExpandQueue: [SearchFolderViewModel] = []
	private var isProcessingExpansions                     = false
	private let expansionChunkSize: Int                    = 15   // Tune as needed

    // MARK: - Lifecycle ------------------------------------------------------

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.drawsBackground     = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        outlineView = NSOutlineView()
        outlineView.style                    = .sourceList
        outlineView.selectionHighlightStyle  = .none
        outlineView.columnAutoresizingStyle  = .uniformColumnAutoresizingStyle
        outlineView.headerView               = nil
        outlineView.backgroundColor          = .clear
        // Keep zero inter-cell vertical spacing – cell views already include padding
        outlineView.intercellSpacing         = NSSize(width: 0, height: 0)
        // Explicit row height so rows never collapse to tiny default size
        outlineView.rowHeight                = FontScalePreset.current.rowHeight
        outlineView.usesAutomaticRowHeights  = false
        outlineView.dataSource               = self
        outlineView.delegate                 = self

        let column = NSTableColumn(identifier: .init("MainColumn"))
        outlineView.addTableColumn(column)

        scrollView.documentView = outlineView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBindings()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

		// Attach a menu so right-click events are consumed by *this*
		// outline view instead of falling through to the normal file tree.
		let menu = NSMenu()
		menu.delegate = self
		outlineView.menu = menu
    }

    // MARK: - NSOutlineViewDataSource ---------------------------------------

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
			return dataSnapshot.rootItems.count
        }

        if let fsItem = item as? SearchItemType {
            switch fsItem {
            case .folder(let folder):
				return dataSnapshot.childrenByID[folder.id]?.count ?? 0
            case .file:
                return 0
            }
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int,
                     ofItem item: Any?) -> Any {
        if item == nil {
			let roots = dataSnapshot.rootItems
			guard index >= 0 && index < roots.count else {
				scheduleSnapshotApply()
				return roots.last ?? NSNull()
			}
			return roots[index]
        }

        if let fsItem = item as? SearchItemType {
            switch fsItem {
            case .folder(let folder):
				let children = dataSnapshot.childrenByID[folder.id] ?? []
				guard index >= 0 && index < children.count else {
					scheduleSnapshotApply()
					return children.last ?? NSNull()
                }
				return children[index]
            case .file:
                return NSNull()
            }
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        guard let fsItem = item as? SearchItemType else { return false }
        switch fsItem {
		case .folder(let folder):
			return (dataSnapshot.childrenByID[folder.id]?.isEmpty == false)
		case .file:
			return false
        }
    }

    // MARK: - NSOutlineViewDelegate -----------------------------------------

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {

        guard let fsItem = item as? SearchItemType else { return nil }

        switch fsItem {
        case .folder:
            let cellView = createFolderCellView()
            configureFolderCell(cellView, with: fsItem)
			// print("[SearchFileTreeVC] createFolderCellView for \(String(describing: (fsItem)))")
            return cellView
        case .file:
            let cellView = createFileCellView()
            configureFileCell(cellView, with: fsItem)
			// print("[SearchFileTreeVC] createFileCellView for \(String(describing: (fsItem)))")
            return cellView
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Disable row selection – we don’t use it and it interferes with first-click
        return false
    }

    // MARK: - Binding helpers
    private func setupBindings() {
        cancellables.removeAll()
        guard isViewLoaded else { return }
        setupFontScaleBinding()
        guard let vm = searchViewModel else { return }

        // Ensure we are the dataSource / delegate
        // These lines are now redundant as they are set in loadView()
        // if outlineView.dataSource == nil { outlineView.dataSource = self }
        // if outlineView.delegate   == nil { outlineView.delegate   = self }

		// Reload whenever the root search results array changes, via snapshot apply
        vm.$rootFolders
            .receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
                guard let self else { return }
				self.scheduleSnapshotApply()
			}
            .store(in: &cancellables)
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
		scheduleSnapshotApply(debounce: 0)
		resetVisibleHoverStates()
	}

    /// Called from wrapper dismantle to avoid leakage.
    func cleanupBindings() {
		updateGeneration = UUID()
		outlineUpdates.cancel()
        cancellables.removeAll()

        // Cancel any queued work that could fire after the representable is dismantled.
        snapshotDebounceWorkItem?.cancel()
        snapshotDebounceWorkItem = nil
        snapshotApplyTask?.cancel()
        snapshotApplyTask = nil

        scrollingDebounceTimer?.invalidate()
        scrollingDebounceTimer = nil

        foldersToExpandQueue.removeAll()
        isProcessingExpansions = false
    }

    // MARK: - Cell helpers -----------------------------------------------------
    private func createFileCellView() -> SearchFileCellView {
        let h = FontScalePreset.current.rowHeight
        let cell = SearchFileCellView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
        cell.treeViewController = self
        cell.setupSubviews()
        return cell
    }

    private func createFolderCellView() -> SearchFolderCellView {
        let h = FontScalePreset.current.rowHeight
        let cell = SearchFolderCellView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
        cell.treeViewController = self
        cell.setupSubviews()
        return cell
    }

    private func configureFileCell(_ cell: SearchFileCellView, with item: SearchItemType) {
        guard case .file(let file) = item else { return }
        cell.treeViewController = self
        cell.hoverCheckbox.treeViewController = self
        cell.fileNameTextField.font = FontScalePreset.current.nsFont
        cell.file = file
    }

    private func configureFolderCell(_ cell: SearchFolderCellView, with item: SearchItemType) {
        guard case .folder(let folder) = item else { return }
        cell.treeViewController = self
        cell.hoverCheckbox.treeViewController = self
        cell.folderNameTextField.font = FontScalePreset.current.nsFont
        cell.folder = folder
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        if !isScrolling {
            isScrolling = true
            resetVisibleHoverStates()
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

    /// Clears hover highlights on visible rows
    private func resetVisibleHoverStates() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }

        for row in visible.location ..< visible.location + visible.length {
            guard let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            for column in 0..<outlineView.numberOfColumns {
                if let view = rowView.view(atColumn: column) {
                    (view as? SearchFileCellView)?.resetHoverState()
                    (view as? SearchFolderCellView)?.resetHoverState()
                }
            }
        }
    }

	/// Queues a folder so it will be expanded on the main thread in small batches.
	private func queueFolderForExpansion(_ folder: SearchFolderViewModel) {
		if !foldersToExpandQueue.contains(where: { $0.id == folder.id }) {
			foldersToExpandQueue.append(folder)
		}
		processExpansionQueueIfNeeded()
	}

	private func processExpansionQueueIfNeeded() {
		guard !isProcessingExpansions, !foldersToExpandQueue.isEmpty else { return }
		isProcessingExpansions = true
		DispatchQueue.main.async { [weak self] in
			self?.processNextExpansionBatch()
		}
	}

	private func processNextExpansionBatch() {
		guard !foldersToExpandQueue.isEmpty else {
			isProcessingExpansions = false
			return
		}

		let batch = Array(foldersToExpandQueue.prefix(expansionChunkSize))
		var deferred: [SearchFolderViewModel] = []

		outlineView.beginUpdates()
		for folder in batch {
			let item = SearchItemType.folder(folder)

			// Ensure the item exists in the outline; if not, retry later
			if outlineView.row(forItem: item) < 0 {
				deferred.append(folder)
				continue
			}

			// Expand only when the parent is already expanded (or root)
			if let parent = folder.parent {
				let parentItem = SearchItemType.folder(parent)
				if outlineView.isItemExpanded(parentItem) {
					outlineView.expandItem(item, expandChildren: false)
				} else {
					deferred.append(folder)
				}
			} else {
				// Root items can always be expanded
				outlineView.expandItem(item, expandChildren: false)
			}
		}
		outlineView.endUpdates()

		// Remove processed head portion
		let removeCount = min(expansionChunkSize, foldersToExpandQueue.count)
		foldersToExpandQueue.removeFirst(removeCount)

		// Re-enqueue deferred items at the tail, avoiding duplicates
		if !deferred.isEmpty {
			for f in deferred where !foldersToExpandQueue.contains(where: { $0.id == f.id }) {
				foldersToExpandQueue.append(f)
			}
		}

		if !foldersToExpandQueue.isEmpty {
			DispatchQueue.main.async { [weak self] in
				self?.processNextExpansionBatch()
			}
		} else {
			isProcessingExpansions = false
		}

		// Clear any lingering hover after batch updates apply
		DispatchQueue.main.async { [weak self] in
			self?.resetVisibleHoverStates()
		}
	}

	/// Lightweight: only queue expansions for root result folders.
	/// Child expansions occur as the user interacts or as nodes become visible.
	private func performExpansionSyncInBackground() {
		guard let roots = searchViewModel?.rootFolders else { return }
		
		// 1) Always expand root result folders (maintains previous behaviour).
		for folder in roots {
			queueFolderForExpansion(folder)
		}
		
		// 2) Traverse only along expanded paths to minimize work on large result trees.
		// Parents are always queued before children.
		var bfsQueue: [SearchFolderViewModel] = roots
		var idx = 0
		while idx < bfsQueue.count {
			let current = bfsQueue[idx]
			idx += 1
			
			for child in current.children {
				switch child {
				case .folder(let subfolder):
					// Only queue subfolders that should be expanded
					if subfolder.isExpanded {
						queueFolderForExpansion(subfolder)
						bfsQueue.append(subfolder)
					}
				case .file:
					continue
				}
			}
		}
	}

	// MARK: - NSMenuDelegate ------------------------------------------------

	func menuNeedsUpdate(_ menu: NSMenu) {
		// Clear previous items
		menu.removeAllItems()

		// Identify the clicked row/item
		let mouseLocation = outlineView.convert(NSApp.currentEvent?.locationInWindow ?? .zero,
												from: nil)
		let row = outlineView.row(at: mouseLocation)
		guard row != -1,
				let item = outlineView.item(atRow: row) as? SearchItemType else { return }

		switch item {
		case .file(let fileVM):
			guard let original = fileVM.originalFile else { return }

			let copyItem = NSMenuItem(title: "Copy",
										action: #selector(copyFileContents(_:)),
										keyEquivalent: "")
			copyItem.target = self
			copyItem.representedObject = original
			
			let openItem = NSMenuItem(title: "Open File",
										action: #selector(openFile(_:)),
										keyEquivalent: "")
			openItem.target = self
			openItem.representedObject = original

			let revealItem = NSMenuItem(title: "Reveal in Finder",
										action: #selector(revealInFinder(_:)),
										keyEquivalent: "")
			revealItem.target = self
			revealItem.representedObject = original

			let copyRel = NSMenuItem(title: "Copy Relative Path",
										action: #selector(copyRelativePath(_:)),
										keyEquivalent: "")
			copyRel.target = self
			copyRel.representedObject = original

			let copyFull = NSMenuItem(title: "Copy Full Path",
										action: #selector(copyFullPath(_:)),
										keyEquivalent: "")
			copyFull.target = self
			copyFull.representedObject = original

			menu.addItem(copyItem)
			menu.addItem(openItem)
			menu.addItem(revealItem)
			menu.addItem(copyRel)
			menu.addItem(copyFull)

			// --- Ignore path -------------------------------------------------
			let ignoreItem = NSMenuItem(title: "Ignore Path",
										action: #selector(ignorePathAction(_:)),
										keyEquivalent: "")
			ignoreItem.target = self
			ignoreItem.representedObject = original
			menu.addItem(ignoreItem)

		case .folder(let folderVM):
			guard let original = folderVM.originalFolder else { return }

			let revealItem = NSMenuItem(title: "Reveal in Finder",
										action: #selector(revealFolderInFinder(_:)),
										keyEquivalent: "")
			revealItem.target = self
			revealItem.representedObject = original

			let copyRel = NSMenuItem(title: "Copy Relative Path",
										action: #selector(copyFolderRelativePath(_:)),
										keyEquivalent: "")
			copyRel.target = self
			copyRel.representedObject = original

			let copyFull = NSMenuItem(title: "Copy Full Path",
										action: #selector(copyFolderFullPath(_:)),
										keyEquivalent: "")
			copyFull.target = self
			copyFull.representedObject = original

			menu.addItem(revealItem)
			menu.addItem(copyRel)
			menu.addItem(copyFull)

			// --- Ignore path -------------------------------------------------
			let ignoreFolderItem = NSMenuItem(title: "Ignore Path",
											action: #selector(ignorePathAction(_:)),
											keyEquivalent: "")
			ignoreFolderItem.target = self
			ignoreFolderItem.representedObject = original
			menu.addItem(ignoreFolderItem)
		}
	}

	// MARK: - Context-menu selectors ---------------------------------------

	@objc private func copyFileContents(_ sender: NSMenuItem) {
		guard let file = sender.representedObject as? FileViewModel else { return }
		file.copyContentsToPasteboard()
	}
	
	@objc private func openFile(_ sender: NSMenuItem) {
		guard let file = sender.representedObject as? FileViewModel else { return }
		file.openInDefaultApp()
	}

	@objc private func revealInFinder(_ sender: NSMenuItem) {
		guard let file = sender.representedObject as? FileViewModel else { return }
		file.revealInFinder()
	}

	@objc private func copyRelativePath(_ sender: NSMenuItem) {
		guard let file = sender.representedObject as? FileViewModel else { return }
		file.copyRelativePathToPasteboard()
	}

	@objc private func copyFullPath(_ sender: NSMenuItem) {
		guard let file = sender.representedObject as? FileViewModel else { return }
		file.copyFullPathToPasteboard()
	}

	@objc private func revealFolderInFinder(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		NSWorkspace.shared.selectFile(folder.fullPath, inFileViewerRootedAtPath: "")
	}

	@objc private func copyFolderRelativePath(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(folder.relativePath, forType: .string)
	}

	@objc private func copyFolderFullPath(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(folder.fullPath, forType: .string)
	}

	// MARK: - Ignore helper -------------------------------------------------

	@objc private func ignorePathAction(_ sender: NSMenuItem) {
		if let file = sender.representedObject as? FileViewModel {
			Task { await self.searchViewModel?.fileManager?.ignorePath(fullPath: file.fullPath,
																	isDirectory: false) }
		} else if let folder = sender.representedObject as? FolderViewModel {
			Task { await self.searchViewModel?.fileManager?.ignorePath(fullPath: folder.fullPath,
																	isDirectory: true) }
		}
	}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension SearchFileTreeViewController {
	@MainActor
	private func buildSnapshot() -> OutlineSnapshot {
		let nextGen = dataSnapshotGeneration + 1
		var childrenMap: [UUID: [SearchItemType]] = [:]

		func capture(folder: SearchFolderViewModel) {
			// Convert current children to SearchItemType and store by folder ID
			let converted: [SearchItemType] = folder.children.map { child in
				switch child {
				case .folder(let sub): return .folder(sub)
				case .file(let file):  return .file(file)
				}
			}
			childrenMap[folder.id] = converted

			// Recurse into subfolders
			for child in folder.children {
				if case .folder(let sub) = child {
					capture(folder: sub)
				}
			}
		}

		let rootFolders = searchViewModel?.rootFolders ?? []
		let roots: [SearchItemType] = rootFolders.map { .folder($0) }
		for root in rootFolders {
			capture(folder: root)
		}

		return OutlineSnapshot(
			generation: nextGen,
			rootItems: roots,
			childrenByID: childrenMap
		)
	}

	private func scheduleSnapshotApply(debounce: TimeInterval = 0.05) {
		snapshotApplyTask?.cancel() // ok to keep; we no longer use it
		requestApplySnapshot(debounce: debounce)
	}

	@MainActor
	private func requestApplySnapshot(debounce: TimeInterval = 0.05) {
		let generation = updateGeneration
		outlineUpdates.schedule(after: debounce) { [weak self] in
			guard let self else { return }
			guard self.updateGeneration == generation else { return }
			guard self.isViewLoaded else { return }
			if self.view.window == nil {
				self.requestApplySnapshot(debounce: 0.05)
				return
			}
			self.applyNewSnapshot()
		}
	}

	@MainActor
	private func applyNewSnapshot() {
		let newSnapshot = buildSnapshot()
		dataSnapshotGeneration = newSnapshot.generation
		dataSnapshot = newSnapshot

		outlineView?.reloadData()
		// Re-apply expansion for matched folders
		performExpansionSyncInBackground()
		// Clear any hover visuals after reload/apply
		resetVisibleHoverStates()
	}
}
