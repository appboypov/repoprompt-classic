//
//  FileTreeViewController+Delegate.swift.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-17.
//

import Cocoa

extension FileTreeViewController: NSOutlineViewDelegate {
	private final class CodemapOnlyMenuPayload: NSObject {
		let paths: [String]

		init(paths: [String]) {
			self.paths = paths
			super.init()
		}
	}

	private static let fileCellID       = NSUserInterfaceItemIdentifier("FileCellViewID")
	private static let folderCellID     = NSUserInterfaceItemIdentifier("FolderCellViewID")
	private static let rootFolderCellID = NSUserInterfaceItemIdentifier("RootFolderCellViewID")
	
	func outlineView(_ outlineView: NSOutlineView,
					 viewFor tableColumn: NSTableColumn?,
					 item: Any) -> NSView? {
		// Immediately guard against a non-enum item
		guard let fsItem = item as? FileSystemItemType else {
			return nil
		}
		
		// Handle all folders and files the same way
		switch fsItem {
		case .folder(let folder):
			cacheOutlineItemPointer(item, for: folder.id)
			
			// Use RootFolderCellView for root folders (parent == nil)
			if folder.parent == nil {
				if let cell = outlineView.makeView(withIdentifier: Self.rootFolderCellID,
													owner: self) as? RootFolderCellView {
					configureRootFolderCell(cell, with: fsItem)
					return cell
				}
				let cell = createRootFolderCellView()
				cell.identifier = Self.rootFolderCellID
				configureRootFolderCell(cell, with: fsItem)
				return cell
			}
			
			// Use FolderCellView for non-root folders
			if let cell = outlineView.makeView(withIdentifier: Self.folderCellID,
												owner: self) as? FolderCellView {
				configureFolderCell(cell, with: fsItem)
				return cell
			}
			let cell = createFolderCellView()
			cell.identifier = Self.folderCellID
			configureFolderCell(cell, with: fsItem)
			return cell
			
		case .file:
			if let cell = outlineView.makeView(withIdentifier: Self.fileCellID,
											   owner: self) as? FileCellView {
				configureFileCell(cell, with: fsItem)
				return cell
			}
			let cell = createFileCellView()
			cell.identifier = Self.fileCellID
			configureFileCell(cell, with: fsItem)
			return cell
		}
	}
	
	// Helper methods to create cell views programmatically
	private func createFileCellView() -> FileCellView {
		let h = FontScalePreset.current.rowHeight
		let cellView = FileCellView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
		cellView.setupSubviews() // only once on creation
		return cellView
	}
	
	private func createFolderCellView() -> FolderCellView {
		let h = FontScalePreset.current.rowHeight
		let cellView = FolderCellView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
		cellView.setupSubviews() // only once on creation
		return cellView
	}
	
	private func createRootFolderCellView() -> RootFolderCellView {
		let h = FontScalePreset.current.rowHeight
		let cellView = RootFolderCellView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
		cellView.setupSubviews() // only once on creation
		return cellView
	}
	
	func outlineViewItemDidExpand(_ notification: Notification) {
		guard let rawItem = notification.userInfo?["NSObject"] else { return }
		
		if let fileSystemItem = rawItem as? FileSystemItemType, case .folder(let folder) = fileSystemItem {
			suppressModelExpansionEvents += 1
			folder.setExpanded(true)
			suppressModelExpansionEvents -= 1
			
			// Now that the parent is expanded, queue descendants that are marked expanded.
			// This ensures previously-expanded nested folders are restored after user expands a root.
			if programmaticOutlineDepth == 0 {
				queueExpandedDescendants(of: folder)
			}
		}
		
		// Clear any hover visuals that may linger after rows shift due to expansion
		scheduleHoverReset()
	}
	
	func outlineViewItemDidCollapse(_ notification: Notification) {
		guard let rawItem = notification.userInfo?["NSObject"] else { return }
		
		if let fileSystemItem = rawItem as? FileSystemItemType, case .folder(let folder) = fileSystemItem {
			suppressModelExpansionEvents += 1
			folder.setExpanded(false)
			suppressModelExpansionEvents -= 1
		}
		
		// Clear any hover visuals that may linger after rows shift due to collapse
		scheduleHoverReset()
	}
	
	// Ensure our snapshot has children ready before AppKit expands the row.
	func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
		guard let fsItem = item as? FileSystemItemType,
			  case .folder(let folder) = fsItem else { return true }
		
		// Ignore our own programmatic expands
		if programmaticOutlineDepth > 0 { return true }
		
		// 1) reflect user click in the model (but don't react in the sink)
		suppressModelExpansionEvents += 1
		folder.setExpanded(true)
		suppressModelExpansionEvents -= 1
		
		// 2) premark so snapshot includes children immediately
		premarkExpandedBranch(for: folder)
		
		// 3) snapshot now (coalesced if one is running)
		if isApplyingSnapshot {
			DispatchQueue.main.async { [weak self] in self?.applyNewSnapshot() }
		} else {
			applyNewSnapshot()
		}
		
		// 4) replay already-expanded descendants on next tick (parent will be visible)
		DispatchQueue.main.async { [weak self] in
			self?.queueExpandedDescendants(of: folder)
		}
		
		// Clear any lingering hover after the expand operation is applied
		scheduleHoverReset()
		
		return true
	}
	
	// Keep shallow snapshot lean on collapse.
	func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
		guard let fsItem = item as? FileSystemItemType,
			  case .folder(let folder) = fsItem else { return true }

		if programmaticOutlineDepth > 0 { return true }

		// Flush any stale queued work for this subtree before collapsing
		dropPendingExpansionRequests(under: folder)
		dropPendingCollapseRequests(under: folder)

		// reflect user click in the model (but don't react in the sink)
		suppressModelExpansionEvents += 1
		folder.setExpanded(false)
		suppressModelExpansionEvents -= 1

		// Keep the snapshot shallow without mutating private(set) state here.
		// This removes the folder and all descendants from the expansion gate
		// and bumps the gate version internally.
		unmarkExpandedBranchIncludingSelf(for: folder)

		if isApplyingSnapshot {
			DispatchQueue.main.async { [weak self] in self?.applyNewSnapshot() }
		} else {
			applyNewSnapshot()
		}

		// Clear any lingering hover after the collapse operation is applied
		scheduleHoverReset()
		return true
	}
	
	// Custom row view
	func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
		return FileTreeRowView()
	}
	
	// Context menu support using NSMenuDelegate
	func menuNeedsUpdate(_ menu: NSMenu) {
		// Clear out existing items
		menu.removeAllItems()
		
		// Figure out which row (if any) was right-clicked
		let mouseLocation = outlineView.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
		let row = outlineView.row(at: mouseLocation)
		guard row != -1 else { return }
		
		// Get the actual item
		guard let item = outlineView.item(atRow: row) as? FileSystemItemType else { return }
		let codemapTargets = contextMenuTargets(clickedRow: row)
		let codemapPayload = CodemapOnlyMenuPayload(paths: codemapOnlyPaths(for: codemapTargets))
		
		// Build the menu based on item type
		switch item {
		case .file(let file):
			// Add menu items for files
			let copyItem = NSMenuItem(title: "Copy", action: #selector(copyFileContents(_:)), keyEquivalent: "")
			copyItem.target = self
			copyItem.representedObject = file

			let openItem = NSMenuItem(title: "Open File", action: #selector(openFile(_:)), keyEquivalent: "")
			openItem.target = self
			openItem.representedObject = file
			
			let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
			revealItem.target = self
			revealItem.representedObject = file
			
			let copyRelativePathItem = NSMenuItem(title: "Copy Relative Path", action: #selector(copyRelativePath(_:)), keyEquivalent: "")
			copyRelativePathItem.target = self
			copyRelativePathItem.representedObject = file
			
			let copyFullPathItem = NSMenuItem(title: "Copy Full Path", action: #selector(copyFullPath(_:)), keyEquivalent: "")
			copyFullPathItem.target = self
			copyFullPathItem.representedObject = file
			
			menu.addItem(openItem)
			menu.addItem(copyItem)
			menu.addItem(revealItem)
			menu.addItem(NSMenuItem.separator())
			menu.addItem(copyRelativePathItem)
			menu.addItem(copyFullPathItem)

			menu.addItem(NSMenuItem.separator())

			let ignoreItem = NSMenuItem(
				title: "Ignore Path",
				action: #selector(ignorePathAction(_:)),
				keyEquivalent: ""
			)
			ignoreItem.target = self
			ignoreItem.representedObject = file
			menu.addItem(ignoreItem)

			menu.addItem(NSMenuItem.separator())

			let codemapOnlyItem = NSMenuItem(
				title: "Select as Codemap",
				action: #selector(markCodemapOnlyAction(_:)),
				keyEquivalent: ""
			)
			codemapOnlyItem.target = self
			codemapOnlyItem.representedObject = codemapPayload
			menu.addItem(codemapOnlyItem)
			
	case .folder(let folder):
		// Root-specific actions
		if folder.parent == nil {
			if folder.isSystemRoot {
				// System roots like _git_data get special actions
				let clearCacheItem = NSMenuItem(title: "Clear Git Cache", action: #selector(clearGitCacheAction(_:)), keyEquivalent: "")
				clearCacheItem.target = self
				clearCacheItem.representedObject = folder
				menu.addItem(clearCacheItem)
				menu.addItem(NSMenuItem.separator())
			} else {
				// Normal user roots get standard root actions
				let unloadItem = NSMenuItem(title: "Unload Root", action: #selector(unloadRootFolderAction(_:)), keyEquivalent: "")
				unloadItem.target = self
				unloadItem.representedObject = folder
				menu.addItem(unloadItem)
				
				let moveUpItem = NSMenuItem(title: "Move Root Up", action: #selector(moveRootUpAction(_:)), keyEquivalent: "")
				moveUpItem.target = self
				moveUpItem.representedObject = folder
				moveUpItem.isEnabled = (fileManager.visibleRootFolders.first?.id != folder.id)
				
				let moveDownItem = NSMenuItem(title: "Move Root Down", action: #selector(moveRootDownAction(_:)), keyEquivalent: "")
				moveDownItem.target = self
				moveDownItem.representedObject = folder
				moveDownItem.isEnabled = (fileManager.visibleRootFolders.last?.id != folder.id)
				
				menu.addItem(moveUpItem)
				menu.addItem(moveDownItem)
				menu.addItem(NSMenuItem.separator())
			}
		}
		
		// Expand / Collapse recursively (model + UI)
		let expandItem = NSMenuItem(title: "Expand All", action: #selector(expandFolderRecursively(_:)), keyEquivalent: "")
		expandItem.target = self
		expandItem.representedObject = folder
		
		let collapseItem = NSMenuItem(title: "Collapse All", action: #selector(collapseFolderRecursively(_:)), keyEquivalent: "")
		collapseItem.target = self
		collapseItem.representedObject = folder
		
		menu.addItem(expandItem)
		menu.addItem(collapseItem)

		// Add a separator before common actions
		menu.addItem(NSMenuItem.separator())

			// System roots have limited actions (no Reveal, no Ignore)
			if !folder.isSystemRoot {
				// Add the same file operations that files have
				let revealFolderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealFolderInFinder(_:)), keyEquivalent: "")
				revealFolderItem.target = self
				revealFolderItem.representedObject = folder
				menu.addItem(revealFolderItem)
			}

			let copyFolderRelativePathItem = NSMenuItem(title: "Copy Relative Path", action: #selector(copyFolderRelativePath(_:)), keyEquivalent: "")
			copyFolderRelativePathItem.target = self
			copyFolderRelativePathItem.representedObject = folder
			menu.addItem(copyFolderRelativePathItem)

			// Don't show Copy Full Path for system roots (they have synthetic paths)
			if !folder.isSystemRoot {
				let copyFolderFullPathItem = NSMenuItem(title: "Copy Full Path", action: #selector(copyFolderFullPath(_:)), keyEquivalent: "")
				copyFolderFullPathItem.target = self
				copyFolderFullPathItem.representedObject = folder
				menu.addItem(copyFolderFullPathItem)
			}

			// Don't allow ignoring system roots
			if !folder.isSystemRoot {
				menu.addItem(NSMenuItem.separator())

				let ignoreFolderItem = NSMenuItem(
					title: "Ignore Path",
					action: #selector(ignorePathAction(_:)),
					keyEquivalent: ""
				)
				ignoreFolderItem.target = self
				ignoreFolderItem.representedObject = folder
				menu.addItem(ignoreFolderItem)
			}

			menu.addItem(NSMenuItem.separator())

			let codemapOnlyItem = NSMenuItem(
				title: "Select as Codemap",
				action: #selector(markCodemapOnlyAction(_:)),
				keyEquivalent: ""
			)
			codemapOnlyItem.target = self
			codemapOnlyItem.representedObject = codemapPayload
			menu.addItem(codemapOnlyItem)
		}
	}
	
	// MARK: - Root context actions
	
	@objc private func unloadRootFolderAction(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		fileManager.requestUnloadRootFolder(path: folder.fullPath)
	}
	
	@objc private func moveRootUpAction(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		fileManager.requestMoveRootFolderUp(path: folder.fullPath)
	}
	
	@objc private func moveRootDownAction(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		fileManager.requestMoveRootFolderDown(path: folder.fullPath)
	}
	
	@objc private func clearGitCacheAction(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel,
			folder.isSystemRoot else { return }
		
		// Validate this is actually the _git_data folder (defense-in-depth)
		let gitDataURL = URL(fileURLWithPath: folder.fullPath)
		guard gitDataURL.lastPathComponent == "_git_data" else { return }
		
		// The _git_data folder path is: <workspaceDirectory>/_git_data
		// So workspace directory is the parent of the folder's full path
		let workspaceDirectory = gitDataURL.deletingLastPathComponent()
		
		Task { [weak self] in
			guard let self else { return }
			do {
				let deletedCount = try await self.clearGitSnapshotsInBackground(workspaceDirectory: workspaceDirectory)
				await self.refreshAfterGitCacheClear(deletedCount: deletedCount)
			} catch {
				await MainActor.run {
					print("[GitCache] Failed to clear cache: \(error.localizedDescription)")
				}
			}
		}
	}
	
	/// Performs git snapshot deletion on a background thread to avoid UI freezes.
	private func clearGitSnapshotsInBackground(workspaceDirectory: URL) async throws -> Int {
		try await Task.detached(priority: .utility) {
			let store = GitDiffSnapshotStore()
			return try store.clearAllSnapshots(workspaceDirectory: workspaceDirectory)
		}.value
	}
	
	/// Refreshes the file tree after git cache clear (must run on main actor).
	@MainActor
	private func refreshAfterGitCacheClear(deletedCount: Int) async {
		await fileManager.flushPendingDeltas(aggressive: true)
		
		if deletedCount > 0 {
			print("[GitCache] Cleared \(deletedCount) snapshot(s) from _git_data")
		} else {
			print("[GitCache] No snapshots to clear")
		}
	}
	
	// MARK: - Expand / Collapse (recursive, model + UI)
	
	@objc private func expandFolderRecursively(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		
		// 1) Update model recursively without triggering per-folder sink storms
		suppressModelExpansionEvents += 1
		setExpandedStateRecursively(folder, expanded: true, currentDepth: 0)
		suppressModelExpansionEvents -= 1
		
		// 2) Ensure snapshot includes subtree but respect depth limits
		markExpandedBranchRecursively(for: folder, maxDepth: expansionDepthLimit)
		
		// Avoid expansion-sync replay fighting with our explicit expand-all
		applyNewSnapshot(suppressExpansionSync: true)
		
		// 3) Replay expansion via the queued batch system to keep UI responsive
		queueFolderForExpansion(folder)
		queueExpandedDescendants(of: folder)
		
		scheduleHoverReset()
	}
	
	@objc private func collapseFolderRecursively(_ sender: NSMenuItem) {
		guard let folder = sender.representedObject as? FolderViewModel else { return }
		
		// 1) Prevent queued re-expands/collapses and unmark the whole branch **before** mutating the model
		dropPendingExpansionRequests(under: folder)
		dropPendingCollapseRequests(under: folder)  // Also clear child collapse requests
		unmarkExpandedBranchIncludingSelf(for: folder)
		
		// 2) Update model recursively without reacting in folder sinks
		suppressModelExpansionEvents += 1
		setExpandedStateRecursively(folder, expanded: false, currentDepth: 0)
		suppressModelExpansionEvents -= 1
		
		// 3) Apply a snapshot (once-suppressed) and collapse via the queued batch
		applyNewSnapshot(suppressExpansionSync: true)
		queueFolderForCollapse(folder)
		
		scheduleHoverReset()
	}
	
	/// Helper to flip `isExpanded` for a folder and all its descendants.
	private func setExpandedStateRecursively(_ folder: FolderViewModel, expanded: Bool, currentDepth: Int) {
		let nextDepth = currentDepth + 1
		if nextDepth <= expansionDepthLimit {
			for sub in folder.subfolders {
				setExpandedStateRecursively(sub, expanded: expanded, currentDepth: nextDepth)
			}
		}
		folder.setExpanded(expanded)
	}
	
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
	
	// New folder action handlers
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
			Task { await self.fileManager.ignorePath(fullPath: file.fullPath,
														isDirectory: false) }
		} else if let folder = sender.representedObject as? FolderViewModel {
			Task { await self.fileManager.ignorePath(fullPath: folder.fullPath,
														isDirectory: true) }
		}
	}

	// MARK: - Codemap-only context menu

	@objc private func markCodemapOnlyAction(_ sender: NSMenuItem) {
		guard let payload = sender.representedObject as? CodemapOnlyMenuPayload else { return }
		guard !payload.paths.isEmpty else { return }
		Task { [paths = payload.paths] in
			await fileManager.applyCodemapOnlySelection(paths: paths)
		}
	}

	private func contextMenuTargets(clickedRow: Int) -> [FileSystemItemType] {
		let selectedRows = outlineView.selectedRowIndexes
		if selectedRows.count > 1, selectedRows.contains(clickedRow) {
			return selectedRows.compactMap { outlineView.item(atRow: $0) as? FileSystemItemType }
		}
		guard let item = outlineView.item(atRow: clickedRow) as? FileSystemItemType else { return [] }
		return [item]
	}

	private func codemapOnlyPaths(for items: [FileSystemItemType]) -> [String] {
		var paths: [String] = []
		paths.reserveCapacity(items.count)
		var seen = Set<String>()
		for item in items {
			switch item {
			case .file(let file):
				let path = (file.fullPath as NSString).standardizingPath
				if seen.insert(path).inserted {
					paths.append(path)
				}
			case .folder(let folder):
				let path = (folder.fullPath as NSString).standardizingPath
				if seen.insert(path).inserted {
					paths.append(path)
				}
			}
		}
		return paths
	}
}
