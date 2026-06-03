import Cocoa
import Combine

class HoverButton: NSButton {
	private var trackingArea: NSTrackingArea?
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea = trackingArea {
			removeTrackingArea(trackingArea)
		}
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
		addTrackingArea(trackingArea!)
	}
	
	override func mouseEntered(with event: NSEvent) {
		self.contentTintColor = NSColor.labelColor
	}
	
	override func mouseExited(with event: NSEvent) {
		self.contentTintColor = NSColor.secondaryLabelColor
		super.mouseExited(with: event)
	}
	
	func resetHoverState() {
		self.contentTintColor = NSColor.secondaryLabelColor
	}
}



@MainActor
class RootFolderCellView: NSTableCellView {
	var hoverCheckbox: HoverCheckboxView!
	private var hoverRegion: NSView!
	private var stateCancellable: AnyCancellable?
	
	weak var treeViewController: FileTreeViewController?
	
	var folderIconImageView: NSImageView!
	var folderNameTextField: NSTextField!
	
	/// Current visual style applied to this cell
	private var currentStyle: FolderVisualStyle = .normal
	
	var folder: FolderViewModel? {
		didSet {
			stateCancellable?.cancel()
			
			if let folder = folder {
				setupAccessibility(with: folder.name)
				hoverCheckbox.checkboxState = folder.checkboxState
				
				// Keep checkbox in sync with folder tri-state (skip redundant paints)
				stateCancellable = folder.$checkboxState
					.removeDuplicates()
					.receive(on: DispatchQueue.main)
					.sink { [weak self] newState in
						self?.hoverCheckbox.checkboxState = newState
					}
			}
		}
	}
	
	/// Apply visual styling based on folder type (normal vs system root like _git_data)
	func applyStyle(_ style: FolderVisualStyle) {
		currentStyle = style
		switch style {
		case .normal:
			folderIconImageView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
			folderIconImageView.contentTintColor = nil
			folderNameTextField.textColor = .labelColor
		case .systemRoot:
			// Use a distinct icon and muted color for system/archive folders like _git_data
			folderIconImageView.image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "System folder")
			folderIconImageView.contentTintColor = .tertiaryLabelColor
			folderNameTextField.textColor = .secondaryLabelColor
		}
	}
	
	override init(frame frameRect: NSRect) {
		if FontScalePreset.isDefaultPreset {
			super.init(frame: frameRect)
		} else {
			super.init(frame: NSRect(x: frameRect.origin.x,
									y: frameRect.origin.y,
									width: frameRect.width,
									height: FontScalePreset.cachedRowHeight))
		}
	}
	
	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	func setupSubviews() {
		hoverCheckbox = HoverCheckboxView(frame: .zero)
		hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
		hoverCheckbox.action = { [weak self] in
			guard
				let self,
				let folder = self.folder,
				let fm     = self.treeViewController?.fileManager
			else { return }
			// Centralize toggles for atomic, synchronous subtree updates
			fm.toggleFolder(folder)
		}
		addSubview(hoverCheckbox)
		
		hoverRegion = NSView(frame: .zero)
		hoverRegion.translatesAutoresizingMaskIntoConstraints = false
		hoverRegion.wantsLayer = true
		hoverRegion.layer?.borderWidth = 0
		addSubview(hoverRegion)
		
		folderIconImageView = NSImageView(frame: .zero)
		folderIconImageView.translatesAutoresizingMaskIntoConstraints = false
		folderIconImageView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
		hoverRegion.addSubview(folderIconImageView)
		
		folderNameTextField = NSTextField(labelWithString: "")
		folderNameTextField.translatesAutoresizingMaskIntoConstraints = false
		folderNameTextField.lineBreakMode = .byTruncatingTail
		folderNameTextField.font = FontScalePreset.current.nsFont
		hoverRegion.addSubview(folderNameTextField)
		
		NSLayoutConstraint.activate([
			hoverCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			hoverCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
			hoverCheckbox.widthAnchor.constraint(equalToConstant: 22),
			hoverCheckbox.heightAnchor.constraint(equalToConstant: 22),
			
			hoverRegion.leadingAnchor.constraint(equalTo: hoverCheckbox.trailingAnchor, constant: 4),
			hoverRegion.centerYAnchor.constraint(equalTo: centerYAnchor),
			hoverRegion.heightAnchor.constraint(equalTo: heightAnchor),
			
			folderIconImageView.leadingAnchor.constraint(equalTo: hoverRegion.leadingAnchor, constant: 4),
			folderIconImageView.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			folderIconImageView.widthAnchor.constraint(equalToConstant: 18),
			folderIconImageView.heightAnchor.constraint(equalToConstant: 18),
			
			folderNameTextField.leadingAnchor.constraint(equalTo: folderIconImageView.trailingAnchor, constant: 8),
			folderNameTextField.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			folderNameTextField.trailingAnchor.constraint(equalTo: hoverRegion.trailingAnchor, constant: -8),
			
			hoverRegion.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
		])
		
		setupHoverTracking()
	}
	
	private func setupHoverTracking() {
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		let trackingArea = NSTrackingArea(rect: hoverRegion.bounds,
											options: options,
											owner: self,
											userInfo: nil)
		hoverRegion.addTrackingArea(trackingArea)
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		hoverRegion.trackingAreas.forEach { hoverRegion.removeTrackingArea($0) }
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		let trackingArea = NSTrackingArea(rect: hoverRegion.bounds,
											options: options,
											owner: self,
											userInfo: nil)
		hoverRegion.addTrackingArea(trackingArea)
	}
	
	
	override func mouseDown(with event: NSEvent) {
		super.mouseDown(with: event)
		let ptInCell = convert(event.locationInWindow, from: nil)
		if hoverRegion.frame.contains(ptInCell) {
			let ptInCheckbox = hoverCheckbox.convert(event.locationInWindow, from: nil)
			if !hoverCheckbox.bounds.contains(ptInCheckbox) {
				folder?.toggleExpanded()
			}
		}
	}
	
	override func mouseEntered(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }
		setHoverBorderVisible(true)
	}
	
	override func mouseExited(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }
		setHoverBorderVisible(false)
	}
	
	/// Resets the hover state, clearing any border highlighting.
	func resetHoverState() {
		setHoverBorderVisible(false)
		hoverCheckbox?.resetHoverState()
	}

	private func setHoverBorderVisible(_ visible: Bool) {
		guard let layer = hoverRegion.layer else { return }

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		if visible {
			let radius = FontScalePreset.current.rowHeight / 2
			let borderColor = CGColor.hoverOutline

			if layer.borderWidth != 1 {
				layer.borderWidth = 1
			}
			if let existing = layer.borderColor {
				if existing != borderColor {
					layer.borderColor = borderColor
				}
			} else {
				layer.borderColor = borderColor
			}
			if layer.cornerRadius != radius {
				layer.cornerRadius = radius
			}
			if layer.cornerCurve != .continuous {
				layer.cornerCurve = .continuous
			}
		} else if layer.borderWidth != 0 {
			layer.borderWidth = 0
		}
		CATransaction.commit()
	}
	
	private func setupAccessibility(with name: String) {
		setAccessibilityLabel("Root folder: \(name)")
		hoverCheckbox.setAccessibilityLabel("Select \(name)")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		if (hoverRegion.layer?.borderWidth ?? 0) > 0 {
			setHoverBorderVisible(true)
		}
	}
	
	deinit {
		stateCancellable?.cancel()
	}
}
