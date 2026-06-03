import Cocoa
import Combine

/// Visual style for folder cells - used to distinguish system roots from normal folders
enum FolderVisualStyle {
	case normal
	case systemRoot  // For _git_data and other supplemental system folders
}

@MainActor
class FolderCellView: NSTableCellView {
	var hoverCheckbox: HoverCheckboxView!
	var folderIconImageView: NSImageView!
	var folderNameTextField: NSTextField!
	
	// Reference to parent controller
	weak var treeViewController: FileTreeViewController?
	
	private var hoverRegion: NSView! // visual highlight region for icon+label
	private var clickableArea: NSView! // invisible clickable area covering the entire row
	private var stateCancellable: AnyCancellable?
	/// Current visual style applied to this cell
	private var currentStyle: FolderVisualStyle = .normal
	
	var folder: FolderViewModel? {
		didSet {
			stateCancellable?.cancel()
			guard let folder = folder else { return }
			
			setupAccessibility(with: folder.name)
			hoverCheckbox.checkboxState = folder.checkboxState
			
			// Keep UI in sync with aggregate folder state (skip redundant paints)
			stateCancellable = folder.$checkboxState
				.removeDuplicates()
				.receive(on: DispatchQueue.main)
				.sink { [weak self] newState in
					self?.hoverCheckbox.checkboxState = newState
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
	
	/// Increase height a bit if desired (e.g. ~28)
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
		// 1) Checkbox on the far left (not in the hover region)
		hoverCheckbox = HoverCheckboxView(frame: .zero)
		hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
		hoverCheckbox.action = { [weak self] in
			guard
				let self,
				let folder = self.folder,
				let fm     = self.treeViewController?.fileManager
			else { return }
			// Centralize folder toggles for fast, atomic subtree updates
			fm.toggleFolder(folder)
		}
		addSubview(hoverCheckbox)
		
		// Create clickable area that spans the entire row (except checkbox)
		clickableArea = NSView(frame: .zero)
		clickableArea.translatesAutoresizingMaskIntoConstraints = false
		addSubview(clickableArea)
		
		// 2) The hoverRegion is for visual highlighting of folder icon + label
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
			// Checkbox near left edge
			hoverCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			hoverCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
			hoverCheckbox.widthAnchor.constraint(equalToConstant: 22),
			hoverCheckbox.heightAnchor.constraint(equalToConstant: 22),
			
			// Clickable area spans entire row after checkbox
			clickableArea.leadingAnchor.constraint(equalTo: hoverCheckbox.trailingAnchor, constant: 4),
			clickableArea.trailingAnchor.constraint(equalTo: trailingAnchor),
			clickableArea.topAnchor.constraint(equalTo: topAnchor),
			clickableArea.bottomAnchor.constraint(equalTo: bottomAnchor),
			
			// Hover region (visual highlight) only around icon and label
			hoverRegion.leadingAnchor.constraint(equalTo: hoverCheckbox.trailingAnchor, constant: 4),
			hoverRegion.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
			hoverRegion.centerYAnchor.constraint(equalTo: centerYAnchor),
			hoverRegion.heightAnchor.constraint(equalTo: heightAnchor),
			
			// Icon at 4 pts from hoverRegion leading edge
			folderIconImageView.leadingAnchor.constraint(equalTo: hoverRegion.leadingAnchor, constant: 4),
			folderIconImageView.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			folderIconImageView.widthAnchor.constraint(equalToConstant: 18),
			folderIconImageView.heightAnchor.constraint(equalToConstant: 18),
			
			// Label after icon
			folderNameTextField.leadingAnchor.constraint(equalTo: folderIconImageView.trailingAnchor, constant: 8),
			folderNameTextField.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			folderNameTextField.trailingAnchor.constraint(equalTo: hoverRegion.trailingAnchor, constant: -8)
		])
		
		setupHoverTracking()
	}
	
	private func setupAccessibility(with name: String) {
		setAccessibilityLabel("Folder: \(name)")
		hoverCheckbox.setAccessibilityLabel("Select \(name)")
	}
	
	// Track hover on the entire clickable area
	private func setupHoverTracking() {
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		let trackingArea = NSTrackingArea(rect: clickableArea.bounds,
											options: options,
											owner: self,
											userInfo: nil)
		clickableArea.addTrackingArea(trackingArea)
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		
		// Remove all existing tracking areas
		clickableArea.trackingAreas.forEach { clickableArea.removeTrackingArea($0) }
		
		// Create new tracking area with current bounds
		let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
		let trackingArea = NSTrackingArea(rect: clickableArea.bounds,
										options: options,
										owner: self,
										userInfo: nil)
		clickableArea.addTrackingArea(trackingArea)
		
		// Reset hover state when tracking areas are updated
		//resetHoverState()
	}
	
	override func mouseDown(with event: NSEvent) {
		super.mouseDown(with: event)
		// If the user clicked inside clickableArea (anywhere after checkbox), toggle expanded
		let ptInCell = convert(event.locationInWindow, from: nil)
		if clickableArea.frame.contains(ptInCell) {
			folder?.toggleExpanded()
		}
	}
	
	// Show highlight only in hoverRegion
	override func mouseEntered(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }

		setHoverBorderVisible(true)
	}
	
	override func mouseExited(with event: NSEvent) {
		guard treeViewController?.isScrolling == false else { return }

		setHoverBorderVisible(false)
	}
	
	/// Resets the hover state, clearing any border highlighting
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
	
	deinit { stateCancellable?.cancel() }

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		if (hoverRegion.layer?.borderWidth ?? 0) > 0 {
			setHoverBorderVisible(true)
		}
	}
}
