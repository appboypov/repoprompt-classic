import AppKit
import Markdown

/// Pure-AppKit "bubble" that renders one `AIChatMessage` plus action buttons.
/// ‑ Very first cut – now supports collapse/expand, file diffs placeholder, reasoning popover.
final class ChatBubbleView: NSView {

    // MARK: – Private stored
	let message    : AIChatMessage
    private unowned let viewModel: ChatViewModel

	// Collapse handling for assistant messages
	private var collapsedAssistantContent: Bool = false
	/// Helper flag to record that initial collapse state was set
	private var didInitialCollapseSetup = false

    // MARK: – Sub-views
    private let background   = NSView()
    // All dynamic body items are inserted into this stack
    private let contentStack = NSStackView()
    private var footerStack  : NSStackView?

	// State for collapsible change rows within a file item
	// Key: "item.id-changeIndex", Value: isHidden
	private var changeRowCodeBlockVisibleState: [String: Bool] = [:]
	// NEW: maps changeId ⇒ codeBlockView
	private var changeRowCodeBlockViewMap     : [String: NSView] = [:]

    // MARK: – Life-cycle
    init(message: AIChatMessage, viewModel: ChatViewModel) {
        self.message   = message
        self.viewModel = viewModel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = false        // background handles its own layer
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: – UI construction
    private func buildUI() {
        // ---------- Bubble background ----------
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.backgroundColor = (
            message.isUser
            ? NSColor.systemBlue.withAlphaComponent(0.15)
            : NSColor.systemGray.withAlphaComponent(0.13)
        ).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        // ---------- Content ----------
        contentStack.orientation         = .vertical
        contentStack.alignment           = .leading
        contentStack.spacing             = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(contentStack)

        populateContentStack()

        // ---------- Footer (buttons / tokens / reasoning) ----------
        let buttons   = makeButtonBar()
        let token     = makeTokenIndicator()
        let reasoning = makeReasoningButton()

        let footer  = NSStackView(views: [buttons, token, reasoning].compactMap { $0 })
        footer.orientation = .horizontal
        footer.alignment   = .centerY
        footer.spacing     = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)
        footerStack = footer

        // ---------- Constraints ----------
        let inset: CGFloat = 4
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo:   topAnchor     , constant: inset),
            background.bottomAnchor.constraint(equalTo:bottomAnchor  , constant: -inset),
            background.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])
        if message.isUser {
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset).isActive = true
            background.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60).isActive = true
        } else {
            background.leadingAnchor.constraint(equalTo:  leadingAnchor , constant: inset).isActive = true
            background.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60).isActive = true
        }

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12)
        ])

        if let footer = footerStack {
            NSLayoutConstraint.activate([
                footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
                footer.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -8),
                footer.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 8),
                footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8)
            ])
        } else {
            contentStack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12).isActive = true
        }
    }

    // MARK: – Helpers

    /// Build child views for every ContentItem and insert into `contentStack`.
    /// Collapsible assistant logic uses the same 10-line heuristic as SwiftUI.
    private func populateContentStack() {
        func add(_ v: NSView) { contentStack.addArrangedSubview(v) }

        guard !message.parsedContent.isEmpty else {
            let lbl = makeLabel(text: message.content)
            add(lbl)
            return
        }

		let isAssistant     = !message.isUser
		let isLatest        = viewModel.isLatestMessage(message)
		let containsFile    = message.parsedContent.contains { $0.type == .file }
		let totalLines      = message.parsedContent
								.filter { $0.type == .text || $0.type == .code }
								.map(\.approximateLineEquivalentCount)
								.reduce(0, +)
		let shouldCollapse  = isAssistant && !isLatest && !containsFile && totalLines > 10

		if !didInitialCollapseSetup {
			collapsedAssistantContent = shouldCollapse
			didInitialCollapseSetup = true
		}

		let collapsed = shouldCollapse && collapsedAssistantContent

        func buildPreviewLabel() -> NSView {
            let preview = message.parsedContent
                .filter { $0.type == .text || $0.type == .code }
                .map(\.firstTenLineEquivalents)
                .joined(separator: "\n\n")
            return makeLabel(text: preview)
        }

        func renderBody() {
            contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            if collapsed {
                add(buildPreviewLabel())
            } else {
                for item in message.parsedContent {
                    switch item.type {
                    case .text:
                        add(makeLabel(text: item.content))
                    case .code:
                        add(makeCodeView(source: item.content))
                    case .file:
						add(makeFileChangeView(for: item))
                    }
                }
            }

            if shouldCollapse {
                let btn = NSButton(title: collapsed ? "Show more…" : "Show less",
									target: self, action: #selector(toggleCollapse(_:)))
                btn.bezelStyle = .inline
                btn.setButtonType(.momentaryPushIn)
                add(btn)
            }
        }

        renderBody()
    }

    private func makeLabel(text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 14)
        l.textColor = .labelColor
        l.maximumNumberOfLines = 0
        return l
    }

    private func makeCodeView(source: String) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attr = NSMutableAttributedString(string: source, attributes: [.font: font,
                                                                          .foregroundColor: NSColor.labelColor])
        CodeHighlighter.applyHighlighting(to: attr, code: source)

        let tv = NSTextView()
        tv.textStorage?.setAttributedString(attr)
        tv.isEditable      = false
        tv.isSelectable    = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.07)

        let clip = NSScrollView()
        clip.documentView = tv
        clip.hasVerticalScroller = true
        clip.borderType = .noBorder
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.heightAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return clip
    }

    private func makeMarkdownTextView(text: String) -> NSView {
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = 14
        let doc = Markdown.Document(parsing: text)
        let attributed = compiler.attributedString(from: doc)

        let tv = NSTextView()
        tv.textStorage?.setAttributedString(attributed)
        tv.isEditable      = false
        tv.isSelectable    = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.backgroundColor = .clear

        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }

    private func makeReasoningButton() -> NSView? {
        let reasoningText = message.reasoningContent
            .isEmpty ? viewModel.ephemeralState.reasoningContent(for: message.id) : message.reasoningContent
        guard !reasoningText.isEmpty else { return nil }

		let btn = NSButton(title: "Reasoning", target: self, action: #selector(showReasoning(_:)))
        btn.bezelStyle = .inline
        return btn
    }

    @objc private func showReasoning(_ sender: NSButton) {
        let pop = NSPopover()
        pop.behavior = .transient
        let tv = NSTextView()
        tv.string = viewModel.ephemeralState.reasoningContent(for: message.id)
        tv.isEditable = false
        tv.font = .systemFont(ofSize: 13)
        tv.drawsBackground = false
        let vc = NSViewController()
        vc.view = NSScrollView()
        (vc.view as! NSScrollView).documentView = tv
        vc.view.setFrameSize(NSSize(width: 400, height: 300))
        pop.contentViewController = vc
		pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func makeButtonBar() -> NSStackView {
        var btns: [NSButton] = []

        let copy = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(copyPressed))
        copy.isBordered = false
        btns.append(copy)

        if !message.isUser {
            let fork = NSButton(
                image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) ?? NSImage(),
                target: self,
                action: #selector(forkPressed))
            fork.isBordered = false
            btns.append(fork)
        }

        let del = NSButton(
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(deletePressed))
        del.isBordered = false
        btns.append(del)

        let stack = NSStackView(views: btns)
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 4
        return stack
    }

    private func makeTokenIndicator() -> NSView? {
        guard let inTok = message.promptTokens,
              let outTok = message.completionTokens else { return nil }
        func fmt(_ n: Int) -> String { String(format: "%.1fk", Double(n) / 1_000.0) }
        let label = NSTextField(labelWithString: "T: \(fmt(inTok)) in | \(fmt(outTok)) out")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: – Actions
	@objc private func toggleCollapse(_ sender: Any?) {
		collapsedAssistantContent.toggle()
		populateContentStack()
	}

    @objc private func copyPressed() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.combinedText, forType: .string)
    }

    @objc private func deletePressed() {
        Task { await viewModel.removeMessage(message.id) }
    }

    @objc private func forkPressed() {
        Task { await viewModel.forkChatSession(from: message.id) }
    }

	// MARK: - ActionLabel Equivalent
	private func makeActionLabel(action: String) -> NSView {
		let label = NSTextField(labelWithString: action)
		label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
		let isDarkBackground = BubbleColors.isDarkMode()
		label.textColor = isDarkBackground ? .white : .black
		label.alignment = .center
		label.isBezeled = false
		label.drawsBackground = true
		label.backgroundColor = NSColor(BubbleColors.mediumBlue(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light))
		label.wantsLayer = true
		label.layer?.cornerRadius = 4

		let wrapper = NSView()
		wrapper.addSubview(label)
		label.translatesAutoresizingMaskIntoConstraints = false
		wrapper.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
			label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -6),
			label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
			label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
			wrapper.heightAnchor.constraint(equalTo: label.heightAnchor, constant: 4)
		])
		return wrapper
	}

	// MARK: - ProgressIndicator Equivalent
	private func makeProgressIndicator(status: DelegateEditTask.TaskStatus) -> NSView {
		var color: NSColor = .gray
		var symbol: String = "circle"
		switch status {
		case .pending:
			symbol = "circle"; color = .gray
		case .inProgress:
			let progress = NSProgressIndicator()
			progress.style = .spinning
			progress.controlSize = .small
			progress.startAnimation(nil)
			progress.translatesAutoresizingMaskIntoConstraints = false
			NSLayoutConstraint.activate([
				progress.widthAnchor.constraint(equalToConstant: 12),
				progress.heightAnchor.constraint(equalToConstant: 12)
			])
			return progress
		case .completed:
			symbol = "checkmark.circle.fill"; color = .systemGreen
		case .noChangesMade:
			symbol = "info.circle.fill"; color = .systemBlue
		case .partialFailed:
			symbol = "exclamationmark.triangle.fill"; color = .systemYellow
		case .failed:
			symbol = "xmark.circle.fill"; color = .systemRed
		}

		if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
			let imgView = NSImageView(image: image)
			imgView.contentTintColor = color
			imgView.translatesAutoresizingMaskIntoConstraints = false
			NSLayoutConstraint.activate([
				imgView.widthAnchor.constraint(equalToConstant: 12),
				imgView.heightAnchor.constraint(equalToConstant: 12)
			])
			return imgView
		} else {
			let fallbackLabel = NSTextField(labelWithString: symbol.first?.uppercased() ?? "P")
			fallbackLabel.textColor = color
			return fallbackLabel
		}
	}

	// Helper to format token display
	private func tokenDisplay(for task: DelegateEditTask) -> String {
		func fmt(_ n: Int) -> String { String(format: "%.2fk", Double(n) / 1_000.0) }
		if (task.status == .completed || task.status == .noChangesMade),
			let p = task.promptTokens,
			let c = task.completionTokens {
			return "Tokens: \(fmt(p)) in | \(fmt(c)) out (\(task.modelDisplayName))"
		} else {
			return "Tokens: ~\(fmt(task.tokenEstimate)) streamed (\(task.modelDisplayName))"
		}
	}

	// Extracted error message lookup
	private func errorMessage(for status: DelegateEditTask.TaskStatus) -> String? {
		switch status {
		case .failed(reason: .fileNotSelected):
			return "File is not selected. Please select the file and try again."
		case .failed(reason: .streamError):
			return "Stream resulted in an error. This may be a rate limit issue."
		case .failed(reason: .fileLoadError):
			return "Failed to load file content. Please try again."
		case .noChangesMade:
			return "No changes were made."
		case .partialFailed:
			return "Some requested edits failed or were not applied."
		default:
			return nil
		}
	}

	// MARK: – File-change renderer
	private func makeFileChangeView(for item: ContentItem) -> NSView {
		let fileItemStack = NSStackView()
		fileItemStack.orientation = .vertical
		fileItemStack.alignment = .leading
		fileItemStack.spacing = 8
		fileItemStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

		fileItemStack.wantsLayer = true
		fileItemStack.layer?.backgroundColor = BubbleColors.fileChangeBackground(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light).cgColor
		fileItemStack.layer?.cornerRadius = 8

		// ---------- Header Section ----------
		let headerStack = NSStackView()
		headerStack.orientation = .horizontal
		headerStack.alignment = .firstBaseline
		headerStack.spacing = 8

		let filePathLabel = NSTextField(labelWithString: item.filePath)
		filePathLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
		filePathLabel.textColor = .labelColor
		headerStack.addArrangedSubview(filePathLabel)

		filePathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		filePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let actionLabelView = makeActionLabel(action: item.action)
		headerStack.addArrangedSubview(actionLabelView)
		actionLabelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

		fileItemStack.addArrangedSubview(headerStack)
		NSLayoutConstraint.activate([
			headerStack.widthAnchor.constraint(equalTo: fileItemStack.widthAnchor, constant: -16)
		])

		// ---------- Changes Section ----------
		for (idx, snippet) in item.changes.enumerated() {
			let changeItemStack = NSStackView()
			changeItemStack.orientation = .vertical
			changeItemStack.alignment = .leading
			changeItemStack.spacing = 4

			let changeId = "\(item.id)-\(idx)"
			let isCodeBlockHidden = changeRowCodeBlockVisibleState[changeId, default: true]

			// Clickable Header
			let descriptionButton = NSButton()
			descriptionButton.isBordered = false
			descriptionButton.bezelStyle = .regularSquare
			descriptionButton.wantsLayer = true
			descriptionButton.layer?.backgroundColor = BubbleColors.lightBlue(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light).cgColor
			descriptionButton.layer?.cornerRadius = 6
			descriptionButton.layer?.borderWidth = 1
			descriptionButton.layer?.borderColor = BubbleColors.borderBlue(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light).cgColor
			descriptionButton.target = self
			descriptionButton.action = #selector(toggleChangeDetailVisibility(_:))
			descriptionButton.identifier = NSUserInterfaceItemIdentifier(rawValue: changeId)

			let buttonContentStack = NSStackView()
			buttonContentStack.orientation = .horizontal
			buttonContentStack.alignment = .centerY
			buttonContentStack.spacing = 6
			buttonContentStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

			let changeNumberText = "Change \(idx + 1): "
			var descriptionText = ""
			if idx < item.descriptions.count,
				!item.descriptions[idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				descriptionText = item.descriptions[idx]
			}
			let fullDescriptionText = changeNumberText + descriptionText
			let descriptionLabel = NSTextField(wrappingLabelWithString: fullDescriptionText)
			descriptionLabel.font = NSFont.systemFont(ofSize: 12)
			descriptionLabel.textColor = .labelColor
			descriptionLabel.maximumNumberOfLines = 0
			buttonContentStack.addArrangedSubview(descriptionLabel)
			descriptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

			let chevronImageName = isCodeBlockHidden ? "chevron.right" : "chevron.down"
			if let chevronImage = NSImage(systemSymbolName: chevronImageName, accessibilityDescription: nil) {
				let chevronImageView = NSImageView(image: chevronImage)
				chevronImageView.contentTintColor = .secondaryLabelColor
				buttonContentStack.addArrangedSubview(chevronImageView)
				chevronImageView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
			}

			descriptionButton.addSubview(buttonContentStack)
			buttonContentStack.translatesAutoresizingMaskIntoConstraints = false
			NSLayoutConstraint.activate([
				buttonContentStack.leadingAnchor.constraint(equalTo: descriptionButton.leadingAnchor),
				buttonContentStack.trailingAnchor.constraint(equalTo: descriptionButton.trailingAnchor),
				buttonContentStack.topAnchor.constraint(equalTo: descriptionButton.topAnchor),
				buttonContentStack.bottomAnchor.constraint(equalTo: descriptionButton.bottomAnchor)
			])
			changeItemStack.addArrangedSubview(descriptionButton)
			NSLayoutConstraint.activate([
					descriptionButton.widthAnchor.constraint(equalTo: changeItemStack.widthAnchor)
			])

			if shouldShowLocatingIndicator(item: item, changeIndex: idx, changeSnippet: snippet) {
				let locatingStack = NSStackView()
				locatingStack.orientation = .horizontal
				locatingStack.spacing = 4
				locatingStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
				locatingStack.wantsLayer = true
				locatingStack.layer?.backgroundColor = BubbleColors.warningYellowBackground(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light).cgColor
				locatingStack.layer?.cornerRadius = 6
				locatingStack.layer?.borderColor = BubbleColors.warningYellowBorder(colorScheme: effectiveAppearance.name == .darkAqua ? .dark : .light).cgColor
				locatingStack.layer?.borderWidth = 1

				let locatingLabel = NSTextField(labelWithString: "Locating change")
				locatingLabel.font = NSFont.systemFont(ofSize: 10)
				locatingLabel.textColor = .secondaryLabelColor
				locatingStack.addArrangedSubview(locatingLabel)

				let progress = NSProgressIndicator()
				progress.style = .spinning
				progress.controlSize = .small
				progress.startAnimation(nil)
				locatingStack.addArrangedSubview(progress)
				NSLayoutConstraint.activate([
					progress.widthAnchor.constraint(equalToConstant: 12),
					progress.heightAnchor.constraint(equalToConstant: 12)
				])
				changeItemStack.addArrangedSubview(locatingStack)
			}

			if !snippet.isEmpty {
				let codeBlockView = makeCodeView(source: snippet)
				codeBlockView.isHidden = isCodeBlockHidden
				changeItemStack.addArrangedSubview(codeBlockView)
				changeRowCodeBlockViewMap[changeId] = codeBlockView
				NSLayoutConstraint.activate([
					codeBlockView.widthAnchor.constraint(equalTo: changeItemStack.widthAnchor)
				])
			}
			fileItemStack.addArrangedSubview(changeItemStack)
			NSLayoutConstraint.activate([
				changeItemStack.widthAnchor.constraint(equalTo: fileItemStack.widthAnchor, constant: -16)
			])
		}

		// ---------- Delegate Edit Tasks Section ----------
		if let tasks = viewModel.delegateEditTasks[message.id],
			let task = tasks.first(where: { $0.filePath == item.filePath || $0.resolvedFilePath == item.filePath }) {

			let taskInfoStack = NSStackView()
			taskInfoStack.orientation = .vertical
			taskInfoStack.alignment = .leading
			taskInfoStack.spacing = 2
			taskInfoStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
			taskInfoStack.wantsLayer = true
			taskInfoStack.layer?.borderColor = NSColor.separatorColor.cgColor
			taskInfoStack.layer?.borderWidth = 0.5
			taskInfoStack.layer?.cornerRadius = 6

			let tokenAndProgressStack = NSStackView()
			tokenAndProgressStack.orientation = .horizontal
			tokenAndProgressStack.spacing = 6
			tokenAndProgressStack.alignment = .centerY

			let tokenLabel = NSTextField(labelWithString: tokenDisplay(for: task))
			tokenLabel.font = NSFont.systemFont(ofSize: 10)
			tokenLabel.textColor = .secondaryLabelColor
			tokenAndProgressStack.addArrangedSubview(tokenLabel)

			let progressIndicatorView = makeProgressIndicator(status: task.status)
			tokenAndProgressStack.addArrangedSubview(progressIndicatorView)

			taskInfoStack.addArrangedSubview(tokenAndProgressStack)

			if let errorMsg = errorMessage(for: task.status) {
				let errorLabel = NSTextField(wrappingLabelWithString: errorMsg)
				errorLabel.font = NSFont.systemFont(ofSize: 10)
				errorLabel.textColor = .systemRed
				errorLabel.maximumNumberOfLines = 0
				taskInfoStack.addArrangedSubview(errorLabel)
			}
			fileItemStack.addArrangedSubview(taskInfoStack)
			NSLayoutConstraint.activate([
				taskInfoStack.widthAnchor.constraint(equalTo: fileItemStack.widthAnchor, constant: -16)
			])
		}

		return fileItemStack
	}

	@objc private func toggleChangeDetailVisibility(_ sender: NSButton) {
		guard let changeId = sender.identifier?.rawValue,
		let codeBlockView = changeRowCodeBlockViewMap[changeId] else { return }

		let currentVisibility = changeRowCodeBlockVisibleState[changeId, default: true]
		let newVisibility = !currentVisibility
		changeRowCodeBlockVisibleState[changeId] = newVisibility
		codeBlockView.isHidden = newVisibility

		if let buttonContentStack = sender.subviews.first(where: { $0 is NSStackView }) as? NSStackView,
			let chevronImageView = buttonContentStack.arrangedSubviews.compactMap({ $0 as? NSImageView }).first {
			let chevronImageName = newVisibility ? "chevron.right" : "chevron.down"
			if let newImage = NSImage(systemSymbolName: chevronImageName, accessibilityDescription: nil) {
				chevronImageView.image = newImage
			}
		}
		needsLayout = true
		superview?.needsLayout = true
	}

	private func shouldShowLocatingIndicator(item: ContentItem, changeIndex: Int, changeSnippet: String) -> Bool {
		changeIndex < item.descriptions.count &&
		!item.descriptions[changeIndex].isEmpty &&
		changeSnippet.isEmpty &&
		item.action.lowercased() == "modify" &&
		!message.isFinalized
	}
}

extension NSColor {
	func isDarkForContrast() -> Bool {
		guard let colorSpaceCorrected = usingColorSpace(.sRGB) else { return false }
		let red = colorSpaceCorrected.redComponent
		let green = colorSpaceCorrected.greenComponent
		let blue = colorSpaceCorrected.blueComponent
		let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
		return luminance < 0.5
	}
}
