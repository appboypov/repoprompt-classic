//
//  FileTreeViewController+DataSource.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-17.
//

import Cocoa

extension FileTreeViewController: NSOutlineViewDataSource {
	func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		if item == nil {
			return snapshotRootItems().count
		}
		
		if let fileSystemItem = item as? FileSystemItemType {
			switch fileSystemItem {
			case .folder(let folder):
				return snapshotChildren(of: folder).count
			case .file:
				return 0
			}
		}
		
		return 0
	}
	
	func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		if item == nil {
			// Root level
			let roots = snapshotRootItems()
			guard index >= 0 && index < roots.count else {
				return roots.last ?? NSNull()
			}
			return roots[index]
		}
		
		if let fileSystemItem = item as? FileSystemItemType {
			switch fileSystemItem {
			case .folder(let folder):
				let children = snapshotChildren(of: folder)
				guard index >= 0 && index < children.count else {
					return children.last ?? NSNull()
				}
				return children[index]
			case .file:
				return NSNull()
			}
		}
		
		return NSNull()
	}
	
	func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
		guard let fileSystemItem = item as? FileSystemItemType else { return false }
		
		switch fileSystemItem {
		case .folder:
			return true       // Always show the triangle; load children on demand
		case .file:
			return false
		}
	}
	
	func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
		// This is needed for non-view-based outline views, but we're using view-based
		// We'll return the item name for debugging purposes
		
		if let fileSystemItem = item as? FileSystemItemType {
			switch fileSystemItem {
			case .folder(let folder):
				return folder.name
			case .file(let file):
				return file.name
			}
		}
		
		return nil
	}
}