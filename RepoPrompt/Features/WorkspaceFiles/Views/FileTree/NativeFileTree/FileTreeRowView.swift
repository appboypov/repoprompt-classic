//
//  FileTreeRowView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-17.
//

import Cocoa

class FileTreeRowView: NSTableRowView {
	override var isOpaque: Bool { false } // Let translucency "through"
	
	override func drawSelection(in dirtyRect: NSRect) {
		if selectionHighlightStyle != .none {
			let selectionRect = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
			NSColor.selectedContentBackgroundColor.setFill()
			let path = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
			path.fill()
		}
	}
	
	// Also override drawBackground to do nothing
	override func drawBackground(in dirtyRect: NSRect) {
		// Intentionally left empty so no background is drawn
	}
}