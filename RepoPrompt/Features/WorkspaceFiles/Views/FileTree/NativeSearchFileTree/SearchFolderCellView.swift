import Cocoa
import Combine

@MainActor
class SearchFolderCellView: NSTableCellView {
    var hoverCheckbox: HoverCheckboxView!
    private var hoverRegion: NSView!
    private var clickableArea: NSView!
    var folderIconImageView: NSImageView!
    var folderNameTextField: NSTextField!

    weak var treeViewController: SearchFileTreeViewController?

    private var stateCancellable: AnyCancellable?

    var folder: SearchFolderViewModel? {
        didSet {
            guard let folder else { return }
            setupAccessibility(with: folder.name)
            hoverCheckbox.checkboxState = folder.checkboxState
            folderNameTextField.attributedStringValue =
                SearchTextHighlighter.make(fullText: folder.name,
                                           query: treeViewController?.searchViewModel?.searchText ?? "",
                                           font: FontScalePreset.current.nsFont)

            stateCancellable?.cancel()
            stateCancellable = folder.$checkboxState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newState in
                    self?.hoverCheckbox.checkboxState = newState
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
        hoverCheckbox.treeViewController = treeViewController
        addSubview(hoverCheckbox)

        hoverRegion = NSView(frame: .zero)
        hoverRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverRegion)

        folderIconImageView = NSImageView(frame: .zero)
        folderIconImageView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        folderIconImageView.translatesAutoresizingMaskIntoConstraints = false
        hoverRegion.addSubview(folderIconImageView)

        folderNameTextField = NSTextField(labelWithString: "")
        folderNameTextField.translatesAutoresizingMaskIntoConstraints = false
        folderNameTextField.lineBreakMode = .byTruncatingTail
        folderNameTextField.maximumNumberOfLines = 1
        folderNameTextField.font = FontScalePreset.current.nsFont
        hoverRegion.addSubview(folderNameTextField)

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

            folderIconImageView.leadingAnchor.constraint(equalTo: hoverRegion.leadingAnchor, constant: 4),
            folderIconImageView.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
            folderIconImageView.widthAnchor.constraint(equalToConstant: 18),
            folderIconImageView.heightAnchor.constraint(equalToConstant: 18),

            folderNameTextField.leadingAnchor.constraint(equalTo: folderIconImageView.trailingAnchor, constant: 8),
            folderNameTextField.centerYAnchor.constraint(equalTo: hoverRegion.centerYAnchor),
            folderNameTextField.trailingAnchor.constraint(equalTo: hoverRegion.trailingAnchor, constant: -8)
        ])

        hoverCheckbox.action = { [weak self] in
            guard let self,
                  let folder = self.folder,
                  let vm = self.treeViewController?.searchViewModel else { return }
            vm.toggleFolderSelection(folder)
        }

        setupHoverTracking()
    }

    // MARK: Hover helpers ---------------------------------------------------------
    private func setupHoverTracking() {
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
        setupHoverTracking()
    }

    // MARK: Click / accessibility -------------------------------------------------
    private func setupAccessibility(with name: String) {
        setAccessibilityLabel("Folder: \(name)")
        hoverCheckbox.setAccessibilityLabel("Select \(name)")
    }

    override func mouseDown(with event: NSEvent) {
        layoutSubtreeIfNeeded()

        // 1. Hit-test in the clickable area (entire row except checkbox)
        let localPoint = clickableArea.convert(event.locationInWindow, from: nil)
        if clickableArea.bounds.contains(localPoint) {
            let cbPoint = hoverCheckbox.convert(event.locationInWindow, from: nil)
            if !hoverCheckbox.bounds.contains(cbPoint) {
                folder?.isExpanded.toggle()
                return                    // handled – skip super
            }
        }

        // 2. Fallback to standard behaviour
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
