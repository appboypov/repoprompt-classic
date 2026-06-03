//
//  FileTreeViewController+CellConfiguration.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-17.
//

import Cocoa

// Cell configuration extension - these methods work with the new diff-based approach
// since they operate on individual cell views and don't depend on the root folders array directly
extension FileTreeViewController {
	/// Configure a folder cell (wrapped in FileSystemItemType.folder).
	func configureFolderCell(_ cellView: FolderCellView, with item: FileSystemItemType) {
		guard case .folder(let folder) = item else { return }
		
		cellView.folderNameTextField.font = FontScalePreset.current.nsFont
		cellView.folderNameTextField.stringValue = folder.name
		updateCheckboxState(cellView.hoverCheckbox, with: folder.checkboxState)
		
		// Set reference to controller
		cellView.treeViewController = self
		cellView.hoverCheckbox.treeViewController = self
		
		// Apply visual style based on folder type
		let style: FolderVisualStyle = folder.isSystemRoot ? .systemRoot : .normal
		cellView.applyStyle(style)
		
		cellView.folder = folder
	}
	
	/// Configure a root folder cell (wrapped in FileSystemItemType.folder with parent == nil).
	func configureRootFolderCell(_ cellView: RootFolderCellView, with item: FileSystemItemType) {
		guard case .folder(let folder) = item else { return }
		
		cellView.folderNameTextField.font = FontScalePreset.current.nsFont
		cellView.folderNameTextField.stringValue = folder.name
		updateCheckboxState(cellView.hoverCheckbox, with: folder.checkboxState)
		
		// Set reference to controller
		cellView.treeViewController = self
		cellView.hoverCheckbox.treeViewController = self
		
		// Apply visual style based on folder type
		let style: FolderVisualStyle = folder.isSystemRoot ? .systemRoot : .normal
		cellView.applyStyle(style)
		
		cellView.folder = folder
	}
	
	func configureFileCell(_ cellView: FileCellView, with item: FileSystemItemType) {
		guard case .file(let file) = item else { return }
		
		cellView.fileNameTextField.font = FontScalePreset.current.nsFont
		cellView.fileNameTextField.stringValue = file.name
		cellView.fileIconImageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
		cellView.hoverCheckbox.checkboxState = file.isChecked ? .checked : .unchecked
		
		// NEW – give the checkbox a direct reference to its file
		cellView.hoverCheckbox.file = file            // ⇐ NEW
		
		// Existing hookups
		cellView.treeViewController = self
		cellView.hoverCheckbox.treeViewController = self
		cellView.file = file
	}
	
	/// Utility to map a CheckboxState to the HoverCheckboxView state
	func updateCheckboxState(_ hoverCheckbox: HoverCheckboxView, with state: CheckboxState) {
		hoverCheckbox.checkboxState = state
		hoverCheckbox.treeViewController = self
	}
}
