import Cocoa
import Combine

@MainActor
class SearchFileCellView: NSTableCellView {
    var hoverCheckbox: HoverCheckboxView!
    var fileIconImageView: NSImageView!
    var fileNameTextField: NSTextField!
    private var hoverRegion: NSView!
    private var clickableArea: NSView!
    private var stateCancellable: AnyCancellable?

    weak var treeViewController: SearchFileTreeViewController?

    var file: SearchFileViewModel? {
        didSet {
            guard let file else { return }
            setupAccessibility(with: file.name)
            hoverCheckbox.checkboxState = file.isChecked ? .checked : .unchecked
            // Highlight matches
            fileNameTextField.attributedStringValue =
                SearchTextHighlighter.make(fullText: file.name,
                                           query: treeViewController?.searchViewModel?.searchText ?? "",
                                           font: FontScalePreset.current.nsFont)

            stateCancellable?.cancel()
            stateCancellable = file.$isChecked
                .receive(on: DispatchQueue.main)
                .sink { [weak self] checked in
                    self?.hoverCheckbox.checkboxState = checked ? .checked : .unchecked
                }
        }
    }

    // MARK: Init -----------------------------------------------------------------
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

    required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: Sub-views -------------------------------------------------------------
    func setupSubviews() {
        // Create the invisible clickable area that spans the entire row
        clickableArea = NSView(frame: .zero)
        clickableArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clickableArea)

        hoverCheckbox = HoverCheckboxView(frame: .zero)
        hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverCheckbox)
        // Provide scroll-state context for hover suppression
        hoverCheckbox.treeViewController = treeViewController

        // Create the visible hover region for icon and label
        hoverRegion = NSView(frame: .zero)
        hoverRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverRegion)
        
        fileIconImageView = NSImageView(frame: .zero)
        fileIconImageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        fileIconImageView.translatesAutoresizingMaskIntoConstraints = false
        hoverRegion.addSubview(fileIconImageView)

        fileNameTextField = NSTextField(labelWithString: "")
        fileNameTextField.translatesAutoresizingMaskIntoConstraints = false
        fileNameTextField.lineBreakMode = .byTruncatingTail
        fileNameTextField.maximumNumberOfLines = 1
        fileNameTextField.font = FontScalePreset.current.nsFont
        hoverRegion.addSubview(fileNameTextField)

        NSLayoutConstraint.activate([
            // Clickable area spans from after checkbox to the end of the row
            clickableArea.leadingAnchor.constraint(equalTo: hoverCheckbox.trailingAnchor, constant: 4),
            clickableArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickableArea.topAnchor.constraint(equalTo: topAnchor),
            clickableArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            hoverCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hoverCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            hoverCheckbox.widthAnchor.constraint(equalToConstant: 22),
            hoverCheckbox.heightAnchor.constraint(equalToConstant: 22),

            // Hover region - no trailing constraint so text can extend beyond visible area
            hoverRegion.leadingAnchor.constraint(equalTo: hoverCheckbox.trailingAnchor, constant: 4),
            hoverRegion.centerYAnchor.constraint(equalTo: centerYAnchor),
            hoverRegion.heightAnchor.constraint(equalTo: heightAnchor),

            fileIconImageView.leadingAnchor.constraint(equalTo: hoverRegion.leadingAnchor, constant: 4),
            fileIconImageView.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
            fileIconImageView.widthAnchor.constraint(equalToConstant: 18),
            fileIconImageView.heightAnchor.constraint(equalToConstant: 18),

            fileNameTextField.leadingAnchor.constraint(equalTo: fileIconImageView.trailingAnchor, constant: 8),
            fileNameTextField.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
            fileNameTextField.trailingAnchor.constraint(equalTo: hoverRegion.trailingAnchor, constant: -8)
        ])

        hoverCheckbox.action = { [weak self] in
            guard let self, let vm = self.treeViewController?.searchViewModel else { return }
            guard let file = self.file else { return }
            Task { await vm.toggleFile(file) }
        }

        setupTrackingArea()
    }

    // MARK: Hover helpers ---------------------------------------------------------
    private func setupTrackingArea() {
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        let area = NSTrackingArea(rect: clickableArea.bounds,
                                  options: opts,
                                  owner: self,
                                  userInfo: nil)
        clickableArea.addTrackingArea(area)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        clickableArea.trackingAreas.forEach { clickableArea.removeTrackingArea($0) }
        setupTrackingArea()
    }

    // MARK: Accessibility & clicks ------------------------------------------------
    private func setupAccessibility(with name: String) {
        setAccessibilityLabel("File: \(name)")
        hoverCheckbox.setAccessibilityLabel("Select \(name)")
    }

	/// Toggle the file immediately when the user clicks anywhere inside
	/// `clickableArea` that is **not** the checkbox.  Converting the point
	/// straight into the region’s own coordinate space avoids relying on its
	/// (possibly not-yet-laid-out) `frame` on first display.
    override func mouseDown(with event: NSEvent) {
		// Make sure sub-views have their latest sizes
		layoutSubtreeIfNeeded()

		// 1. Hit-test in the clickable label+icon region
		let localPoint = clickableArea.convert(event.locationInWindow, from: nil)
		if clickableArea.bounds.contains(localPoint) {
			let cbPoint = hoverCheckbox.convert(event.locationInWindow, from: nil)
			if !hoverCheckbox.bounds.contains(cbPoint) {
				hoverCheckbox.action?()   // toggle include/exclude
				return                    // handled – do NOT call super
            }
        }

		// 2. Any other area: default behaviour (selection, etc.)
		super.mouseDown(with: event)
    }

    // MARK: Hover visuals ---------------------------------------------------------
    override func mouseEntered(with event: NSEvent) {
        guard treeViewController?.isScrolling == false else { return }
		setHoverBorderVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard treeViewController?.isScrolling == false else { return }
		setHoverBorderVisible(false)
    }

    func resetHoverState() {
		setHoverBorderVisible(false)
        hoverCheckbox?.resetHoverState()
    }

	// Keep search file outline colour in sync with appearance
	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		if (hoverRegion.layer?.borderWidth ?? 0) > 0 {
			setHoverBorderVisible(true)
		}
	}

	private func setHoverBorderVisible(_ visible: Bool) {
		if visible && !hoverRegion.wantsLayer {
			hoverRegion.wantsLayer = true
		}
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
}
