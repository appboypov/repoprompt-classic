//
//  NSCheckbox.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-20.
//

import Cocoa

@MainActor
protocol HoverScrollStateProvider: AnyObject {
	var isScrolling: Bool { get }
}

/// A custom checkbox view that looks & feels more like your SwiftUI CheckboxView.
/// Displays checked, mixed, or unchecked states, and shows a highlight on hover.
@MainActor
class HoverCheckboxView: NSView {
	// Reference to parent controller
	weak var treeViewController: HoverScrollStateProvider?
	
	// NEW property just below weak var treeViewController
	weak var file: FileViewModel?
	
	// Set this to update the displayed symbol (square, minus.square, checkmark.square).
	var checkboxState: CheckboxState = .unchecked {
		didSet {
			updateAppearance(animated: true)
		}
	}
	
	// Static image cache to avoid repeated symbol loading
	private static var imageCache: [String: NSImage] = [:]
	
	/// Called whenever the user clicks the checkbox.
	var action: (() -> Void)?
	
	private let imageView = NSImageView()
	private var isHovering = false {
		didSet {
			updateAppearance(animated: true)
		}
	}
	
	// We’ll track hovering via an NSTrackingArea.
	private var trackingAreaObject: NSTrackingArea?
	
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		commonInit()
	}
	
	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}
	
	private func commonInit() {
		wantsLayer = true
		// Setup the SF Symbol image view
		imageView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(imageView)
		
		// Ensure layer-backed for faster tinting and updates
		imageView.wantsLayer = true
		imageView.imageScaling = .scaleProportionallyDown
		
		NSLayoutConstraint.activate([
			imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
			imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
		
		// Give ourselves a default size of ~20x20
		setFrameSize(NSSize(width: 20, height: 20))
		
		// Create the tracking area for mouseEnter/mouseExit
		updateTrackingAreas()
		
		// Initial appearance (no animation)
		updateAppearance(animated: false)
	}
	
	override func mouseDown(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }

		if event.modifierFlags.contains(.shift),
			let controller = treeViewController as? FileTreeViewController,
			let linkedFile = file {
			controller.handleShiftClick(on: linkedFile)
			return // ⇧‑click handled – stop
		}

		// ▼ NEW – remember the anchor on a normal click
		if let controller = treeViewController as? FileTreeViewController,
			let linkedFile = file {
			controller.setShiftSelectionAnchor(linkedFile)
		}

		super.mouseDown(with: event) // highlight, etc.
		action?() // toggle the checkbox
	}
	
	override func mouseEntered(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }

		super.mouseEntered(with: event)
		isHovering = true
		// Redraw to show hover background only when hover changes
		needsDisplay = true
	}
	
	override func mouseExited(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }

		super.mouseExited(with: event)
		isHovering = false
		// Redraw to clear hover background only when hover changes
		needsDisplay = true
	}
	
	/// Resets the hover state to avoid lingering highlights.
	func resetHoverState() {
		isHovering = false
	}
	
	// Because we're using .inVisibleRect, we must update the tracking area if our bounds change.
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let oldArea = trackingAreaObject {
			removeTrackingArea(oldArea)
		}
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
		addTrackingArea(area)
		trackingAreaObject = area
		
		// Explicitly reset hover state
		//resetHoverState()
	}
	
	// MARK: - Cache Management
	
	/// Clears the static image cache. Useful for memory management or configuration changes.
	static func clearImageCache() {
		imageCache.removeAll()
	}
	
	// MARK: - Appearance
	private func updateAppearance(animated: Bool) {
		// Choose the SF Symbol name based on state
		let symbolName: String
		switch checkboxState {
		case .checked:
			symbolName = "checkmark.square"
		case .mixed:
			symbolName = "minus.square"
		case .unchecked:
			symbolName = "square"
		}
		
		// Choose a color based on state + hover
		let color: NSColor
		switch checkboxState {
		case .checked, .mixed:
			color = .controlAccentColor
		case .unchecked:
			color = isHovering ? .labelColor : .secondaryLabelColor
		}
		
		// Reuse configured template image per symbol name
		if let cached = Self.imageCache[symbolName] {
			if imageView.image !== cached {
				imageView.image = cached
			}
		} else {
			if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
				// Apply a shared symbol configuration once (size/weight/scale)
				let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
				let configured = base.withSymbolConfiguration(config) ?? base
				configured.isTemplate = true
				Self.imageCache[symbolName] = configured
				imageView.image = configured
			} else {
				imageView.image = nil
			}
		}
		
		// Apply tint via view property (cheaper than regenerating colored images)
		imageView.contentTintColor = color
		// No fade animations; no blanket redraws here
	}
	
	// Draw the SwiftUI-like hover background
	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)
		
		// If we want a subtle background shape only when hovering:
		if isHovering {
			let cornerRadius: CGFloat = 4
			let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
			NSColor.secondaryLabelColor.withAlphaComponent(0.2).setFill()
			path.fill()
		}
	}
	
	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		// Re-update appearance to use new colors
		updateAppearance(animated: false)
	}
}

extension NSColor {
	// Adjust the brightness of a color by a delta value
	func withBrightnessDelta(_ delta: CGFloat) -> NSColor {
		var hue: CGFloat = 0
		var saturation: CGFloat = 0
		var brightness: CGFloat = 0
		var alpha: CGFloat = 1
		
		// Convert to a color space that supports HSB
		let colorInRGB = self.usingColorSpace(.deviceRGB)
		
		colorInRGB?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
		brightness = max(0, min(1, brightness + delta))
		
		return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
	}
	
	// Convenience method to lighten a color
	func lightened(amount: CGFloat) -> NSColor {
		let change = min(max(0, amount), 1)
		return self.withBrightnessDelta(change)
	}
	
	// Convenience method to darken a color
	func darkened(amount: CGFloat) -> NSColor {
		let change = -min(max(0, amount), 1)
		return self.withBrightnessDelta(change)
	}
	
	// Static property for SwiftUI-like accent color
	static var swiftUIAccentColor: NSColor {
		// Lighten the accent color to match SwiftUI's accent color
		return NSColor.systemBlue.lightened(amount: 0.5)
	}
}
