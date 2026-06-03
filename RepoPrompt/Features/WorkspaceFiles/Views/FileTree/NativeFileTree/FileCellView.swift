import Cocoa
import Combine

@MainActor
class FileCellView: NSTableCellView {
	var hoverCheckbox: HoverCheckboxView!
	var fileIconImageView: NSImageView!
	var fileNameTextField: NSTextField!
	private var stateCancellable: AnyCancellable?
	private var hoverRegion: NSView! // visual highlight for icon+label
	private var clickableArea: NSView! // entire row click area
	
	// Reference to parent controller
	weak var treeViewController: FileTreeViewController?
	
	var file: FileViewModel? {
		didSet {
			stateCancellable?.cancel()
			guard let file = file else { return }
			
			hoverCheckbox.file = file
			setupAccessibility(with: file.name)
			hoverCheckbox.checkboxState = file.isChecked ? .checked : .unchecked
			
			// Keep UI in sync without forcing row reloads (skip redundant paints)
			stateCancellable = file.$isChecked
				.removeDuplicates()
				.receive(on: DispatchQueue.main)
				.sink { [weak self] checked in
					self?.hoverCheckbox.checkboxState = checked ? .checked : .unchecked
				}
		}
	}
	
	/// Increase the default height slightly (e.g. from ~24 to ~28)
	override init(frame frameRect: NSRect) {
		// Row height is handled by outline rowHeight; no need to compute here.
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
		// Make the checkbox ~10% larger (was 20, now 22)
		hoverCheckbox = HoverCheckboxView(frame: .zero)
		hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
		hoverCheckbox.action = { [weak self] in
			// Centralize toggling via the manager for consistent batching + parent updates
			guard
				let self,
				let file = self.file,
				let fm   = self.treeViewController?.fileManager
			else { return }
			fm.toggleFile(file)
		}
		addSubview(hoverCheckbox)
		
		// Create clickable area that spans the entire row (except checkbox)
		clickableArea = NSView(frame: .zero)
		clickableArea.translatesAutoresizingMaskIntoConstraints = false
		addSubview(clickableArea)
		
		// Create hover region for visual highlight
		hoverRegion = NSView(frame: .zero)
		hoverRegion.translatesAutoresizingMaskIntoConstraints = false
		hoverRegion.wantsLayer = true
		hoverRegion.layer?.borderWidth = 0
		addSubview(hoverRegion)
		
		// Icon from 16→18 to be ~10% larger
		fileIconImageView = NSImageView(frame: .zero)
		fileIconImageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
		fileIconImageView.translatesAutoresizingMaskIntoConstraints = false
		hoverRegion.addSubview(fileIconImageView)
		
		fileNameTextField = NSTextField(labelWithString: "")
		fileNameTextField.translatesAutoresizingMaskIntoConstraints = false
		fileNameTextField.lineBreakMode = .byTruncatingTail
		fileNameTextField.font = FontScalePreset.current.nsFont
		hoverRegion.addSubview(fileNameTextField)
		
		NSLayoutConstraint.activate([
			// Checkbox directly from left edge
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
			hoverRegion.centerYAnchor.constraint(equalTo: centerYAnchor),
			hoverRegion.heightAnchor.constraint(equalTo: heightAnchor),
			
			// Icon at 4 pts from hoverRegion's leading edge
			fileIconImageView.leadingAnchor.constraint(equalTo: hoverRegion.leadingAnchor, constant: 4),
			fileIconImageView.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			fileIconImageView.widthAnchor.constraint(equalToConstant: 18),
			fileIconImageView.heightAnchor.constraint(equalToConstant: 18),
			
			// Label 8 pts from icon
			fileNameTextField.leadingAnchor.constraint(equalTo: fileIconImageView.trailingAnchor, constant: 8),
			fileNameTextField.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
			fileNameTextField.trailingAnchor.constraint(equalTo: hoverRegion.trailingAnchor, constant: -8)
		])
		
		setupTrackingArea()
	}
	
	private func setupTrackingArea() {
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
	
	private func setupAccessibility(with name: String) {
		setAccessibilityLabel("File: \(name)")
		hoverCheckbox.setAccessibilityLabel("Select \(name)")
	}
	
	override func mouseDown(with event: NSEvent) {
		super.mouseDown(with: event)
		guard let tvc  = treeViewController,
				let file = self.file else { return }

		// Check if click is in the clickable area (anywhere after checkbox)
		let pt = convert(event.locationInWindow, from: nil)
		let inClickable = clickableArea.frame.contains(pt)

		// ⇧‑click anywhere in the row (except when scrolling is suppressed)
		if event.modifierFlags.contains(.shift) && !tvc.isScrolling {
			tvc.handleShiftClick(on: file)
			return
		}

		// Normal click → update anchor & toggle when in clickable area
		tvc.setShiftSelectionAnchor(file)
		if inClickable {
			tvc.fileManager.toggleFile(file) // centralized & batched
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

	/// Called by AppKit whenever Light/Dark mode changes.
	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		if (hoverRegion.layer?.borderWidth ?? 0) > 0 {
			setHoverBorderVisible(true)
		}
	}
}
