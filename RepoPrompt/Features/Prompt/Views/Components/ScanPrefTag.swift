import SwiftUI

struct CircularProgressView: View {
	let progress: Double  // 0.0 to 1.0
	var fontPreset: FontScalePreset = .normal
	
	var body: some View {
		ZStack {
			Circle()
				.stroke(lineWidth: 2 * fontPreset.scaleFactor)
				.opacity(0.3)
				.foregroundColor(.blue)
			Circle()
				.trim(from: 0, to: progress)
				.stroke(style: StrokeStyle(lineWidth: 2 * fontPreset.scaleFactor, lineCap: .round))
				.foregroundColor(.blue)
				.rotationEffect(.degrees(-90))
				.animation(.linear, value: progress)
			Text("\(Int(progress * 100))")
				.font(.system(size: 8 * fontPreset.scaleFactor))
				.foregroundColor(.blue)
		}
	}
}

struct ScanFilesPrefTag: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var promptManager: PromptViewModel  // binding to the prompt model
	var context: SettingsContext = .copy
	/// Indicates that the tag is being shown inside the Chat UI.
	/// When `false` (default) we suppress the edit-mode warning visuals.
	var isChatContext: Bool = false
	var isLocked: Bool = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	@State private var progressFraction: Double = 0.0
	@State private var isComplete: Bool = true
	@State private var showPopover = false
	@State private var isHovering = false
	@State var id: UUID = UUID()

	private var currentCodeMapUsage: CodeMapUsage {
		switch context {
		case .copy: return promptManager.codeMapUsage
		case .chat: return promptManager.codeMapUsageForChat
		}
	}

	private var isGloballyDisabled: Bool {
		promptManager.codeMapsGloballyDisabled
	}

	private var effectiveCodeMapUsage: CodeMapUsage {
		isGloballyDisabled ? .none : currentCodeMapUsage
	}
	
	private var tagHorizontalPadding: CGFloat { fontPreset.scaledClamped(8, min: 8, max: 12) }
	private var tagVerticalPadding: CGFloat { fontPreset.scaledClamped(4, min: 4, max: 7) }
	private var tagMinHeight: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 36) }
	private var tagCornerRadius: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 20) }
	private var tagSpacing: CGFloat { fontPreset.scaledClamped(8, min: 8, max: 10) }
	private var indicatorSize: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 21) }
	private var indicatorIconSize: CGFloat { fontPreset.scaledClamped(12, min: 12, max: 15) }

	private var codeMapTooltip: String {
		if isGloballyDisabled {
			return "Code Maps are globally disabled in Advanced Settings. Per-workspace modes are preserved but currently inactive."
		}

		var tooltip = "Code Maps: Compressed file overviews\n"
		tooltip += "Shows functions, classes, and imports"
		
		return tooltip
	}

	/// Dynamic background color that adapts to warning & hover state
	private var backgroundColor: Color {
		if isGloballyDisabled {
			return isHovering
				? Color.orange.opacity(0.18)
				: Color.orange.opacity(0.1)
		} else if isWarningState {
			return isHovering
				? Color.yellow.opacity(0.3)
				: Color.yellow.opacity(0.2)
		} else if effectiveCodeMapUsage != .none {
			return isHovering
				? Color.blue.opacity(0.2)
				: Color.blue.opacity(0.1)
		} else {
			return isHovering
				? Color.gray.opacity(0.2)
				: Color.gray.opacity(0.1)
		}
	}

	// MARK: – Warning logic
	/// True when code-map mode is "selected" **and** the chat is in Edit mode.
	private var isWarningState: Bool {
		// Warning is only relevant in chat view when both conditions are met.
		guard isChatContext, !isGloballyDisabled else { return false }
		return currentCodeMapUsage == .selected &&
			promptManager.planActMode == .edit
	}
	
	var body: some View {
		content
			.padding(.horizontal, tagHorizontalPadding)
			.padding(.vertical, tagVerticalPadding)
			.frame(minHeight: tagMinHeight)
			.background(backgroundColor)
			.cornerRadius(tagCornerRadius)
			.overlay(
				RoundedRectangle(cornerRadius: tagCornerRadius)
					.stroke(borderColor, lineWidth: 1)
			)
			.onTapGesture { showPopover.toggle() }
			.hoverTooltip(codeMapTooltip)
			.popover(isPresented: $showPopover, arrowEdge: .leading) {
				popoverContent
			}
			.onAppear {
				updateProgressState()
			}
			// Debounce frequent scan updates to reduce UI churn
			.onChange(of: fileManager.remainingScanCount) { _, _ in
				debounceProgressUpdate()
			}
			.onHover { hovering in
				withAnimation(.easeInOut(duration: 0.1)) {
					isHovering = hovering
				}
			}
	}
	
	private var borderColor: Color {
		if isGloballyDisabled { return Color.orange.opacity(0.35) }
		return effectiveCodeMapUsage != .none ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3)
	}

	// Main content view (the label)
	private var content: some View {
		HStack(spacing: tagSpacing) {
			Text("Code Map")
				.font(fontPreset.font)
				.foregroundColor(.primary)
				.lineLimit(1)
				.layoutPriority(1)
			statusIndicator
		}
	}
	
	// Computed property that returns the appropriate icon name based on the code map mode.
	private var modeIconName: String {
		if isGloballyDisabled { return "slash.circle" }
		// When in warning state we ignore normal mapping and show a triangle.
		if isWarningState { return "exclamationmark.triangle.fill" }
		switch effectiveCodeMapUsage {
		case .auto:
			return "arrow.triangle.2.circlepath.circle"
		case .complete:
			return "checkmark.circle.fill"
		case .selected:
			return "target"           // new icon
		case .none:
			return "xmark.circle"
		}
	}
	
	// Status indicator (shows circular progress when scanning, otherwise an icon reflecting the mode)
	private var statusIndicator: some View {
		Group {
			if isGloballyDisabled {
				Image(systemName: modeIconName)
					.foregroundColor(.orange)
					.font(.system(size: indicatorIconSize))
					.frame(width: indicatorSize, height: indicatorSize)
					.transition(.scale)
			} else if isWarningState {
				// Yellow warning triangle
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.yellow)
					.font(.system(size: indicatorIconSize))
					.frame(width: indicatorSize, height: indicatorSize)
					.transition(.scale)
			} else if !isComplete {
				CircularProgressView(progress: progressFraction, fontPreset: fontPreset)
					.frame(width: indicatorSize, height: indicatorSize)
					.transition(.scale)
			} else {
				Image(systemName: modeIconName)
					.font(.system(size: indicatorIconSize))
					.frame(width: indicatorSize, height: indicatorSize)
					.transition(.scale)
			}
		}
		.animation(.easeInOut, value: isComplete)
	}

	private var popoverContent: some View {
		ScanFilesPopoverContent(
			fileManager: fileManager,
			promptManager: promptManager,
			context: context,
			isChatContext: isChatContext,
			fontPreset: fontPreset,
			isComplete: isComplete,
			progressFraction: progressFraction
		)
		.id(id)
		.padding()
		.frame(width: 350 * fontPreset.scaleFactor)
	}
	
	@State private var progressDebounceTask: Task<Void, Never>? = nil
	
	private func updateProgressState() {
		let total = fileManager.totalFilesSeen
		let remaining = fileManager.remainingScanCount
		if total > 0 && remaining > 0 {
			// Still scanning: compute progress fraction
			progressFraction = Double(total - remaining) / Double(total)
			isComplete = false
		} else {
			// Scan complete (or no files to scan)
			progressFraction = 1.0
			isComplete = true
			promptManager.MarkDirty()
			id = UUID()
		}
	}

	private func debounceProgressUpdate(delayMs: UInt64 = 150) {
		progressDebounceTask?.cancel()
		progressDebounceTask = Task {
			try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				updateProgressState()
			}
		}
	}
}

private struct ScanFilesPopoverContent: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var promptManager: PromptViewModel
	@ObservedObject var tokenCounter: TokenCountingViewModel
	let context: SettingsContext
	let isChatContext: Bool
	let fontPreset: FontScalePreset
	let isComplete: Bool
	let progressFraction: Double

	@State private var showWarningPopover: Bool = false
	@State private var didRequestScanCancel: Bool = false

	init(
		fileManager: RepoFileManagerViewModel,
		promptManager: PromptViewModel,
		tokenCounter: TokenCountingViewModel? = nil,
		context: SettingsContext,
		isChatContext: Bool,
		fontPreset: FontScalePreset,
		isComplete: Bool,
		progressFraction: Double
	) {
		self._fileManager = ObservedObject(wrappedValue: fileManager)
		self._promptManager = ObservedObject(wrappedValue: promptManager)
		self._tokenCounter = ObservedObject(wrappedValue: tokenCounter ?? promptManager.tokenCountingViewModel)
		self.context = context
		self.isChatContext = isChatContext
		self.fontPreset = fontPreset
		self.isComplete = isComplete
		self.progressFraction = progressFraction
	}

	private var currentCodeMapUsage: CodeMapUsage {
		switch context {
		case .copy: return promptManager.codeMapUsage
		case .chat: return promptManager.codeMapUsageForChat
		}
	}

	private var isGloballyDisabled: Bool {
		promptManager.codeMapsGloballyDisabled
	}

	private var effectiveCodeMapUsage: CodeMapUsage {
		isGloballyDisabled ? .none : currentCodeMapUsage
	}

	/// True when code-map mode is "selected" **and** the chat is in Edit mode.
	private var isWarningState: Bool {
		guard isChatContext, !isGloballyDisabled else { return false }
		return currentCodeMapUsage == .selected &&
			promptManager.planActMode == .edit
	}

	/// Languages detected in the most-recent scan.
	private var scannedLanguages: Set<LanguageType> {
		tokenCounter.scannedLanguages
	}

	/// All languages Repo Prompt can generate Code-maps for.
	private var supportedLanguages: [LanguageType] {
		Array(Set(SyntaxManager.shared.extensionToLanguage.values))
			.sorted { $0.rawValue < $1.rawValue }
	}

	/// A compact horizontal display showing only the scanned languages
	private var languagesLegend: some View {
		let availableWidth = 260 * fontPreset.scaleFactor
		let itemsPerRow = 4
		let sortedLanguages = Array(scannedLanguages).sorted(by: { $0.rawValue < $1.rawValue })
		let rows = sortedLanguages.chunked(into: itemsPerRow)

		return VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
			if scannedLanguages.isEmpty {
				Text("No supported languages detected")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			} else {
				ForEach(rows.indices, id: \.self) { rowIndex in
					let row = rows[rowIndex]
					HStack(spacing: 4 * fontPreset.scaleFactor) {
						ForEach(row, id: \.self) { lang in
							Text(lang.displayName)
								.font(.system(size: 10 * fontPreset.scaleFactor, weight: .medium))
								.padding(.horizontal, 8 * fontPreset.scaleFactor)
								.padding(.vertical, 4 * fontPreset.scaleFactor)
								.background(languageColor(for: lang))
								.foregroundColor(.primary.opacity(0.8))
								.cornerRadius(4)
						}
						Spacer(minLength: 0)
					}
				}
			}
		}
		.frame(width: availableWidth, alignment: .leading)
	}

	/// Returns a color for the given language type
	private func languageColor(for language: LanguageType) -> Color {
		switch language {
		case .swift:
			return Color.orange.opacity(0.6)
		case .js, .ts, .tsx:
			return Color.yellow.opacity(0.5)
		case .python:
			return Color.blue.opacity(0.5)
		case .rust:
			return Color.red.opacity(0.5)
		case .go:
			return Color.cyan.opacity(0.5)
		case .java:
			return Color.purple.opacity(0.5)
		case .c, .cpp:
			return Color.green.opacity(0.5)
		case .c_sharp:
			return Color.indigo.opacity(0.5)
		case .dart:
			return Color.teal.opacity(0.5)
		case .ruby:
			return Color.red.opacity(0.4)
		case .php:
			return Color.pink.opacity(0.5)
		}
	}

	private var globalDisabledBanner: some View {
		HStack(alignment: .top, spacing: 8 * fontPreset.scaleFactor) {
			Image(systemName: "slash.circle")
				.foregroundColor(.orange)
			Text("Code Maps are globally disabled in Advanced Settings. Saved copy/chat modes are preserved; effective mode is None.")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(8 * fontPreset.scaleFactor)
		.background(Color.orange.opacity(0.1))
		.cornerRadius(8)
	}

	// Existing code-map controls
	private var codeMapControls: some View {
		VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
			if isGloballyDisabled {
				globalDisabledBanner
			}

			HStack {
				Text("Code Map Usage")
					.font(fontPreset.headlineFont)
				// Small warning chip right of the title; appears only in warning state (opacity-based, no layout jump)
				Button(action: { showWarningPopover.toggle() }) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.yellow)
						.font(.system(size: 12 * fontPreset.scaleFactor))
						.padding(.horizontal, 2 * fontPreset.scaleFactor)
				}
				.buttonStyle(PlainButtonStyle())
				.opacity(isWarningState ? 1.0 : 0.0)
				.allowsHitTesting(isWarningState)
				.animation(.easeInOut(duration: 0.15), value: isWarningState)
				.popover(isPresented: $showWarningPopover, arrowEdge: .top) {
					VStack(alignment: .leading, spacing: 8 * fontPreset.scaleFactor) {
						HStack(spacing: 8 * fontPreset.scaleFactor) {
							Image(systemName: "exclamationmark.triangle.fill")
								.foregroundColor(.yellow)
							Text("Code‑map warning")
								.font(fontPreset.headlineFont)
						}
						Text("Using \"Selected\" code‑map mode while in Edit mode will prevent file edits from being applied because full file contents are replaced with code‑maps.")
							.font(fontPreset.captionFont)
							.fixedSize(horizontal: false, vertical: true)
						Text("Switch to Auto, None or Complete mode—or exit Edit mode—if you intend to modify files.")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding()
					.frame(width: 320 * fontPreset.scaleFactor)
				}
				Spacer()
				Spacer()
				// Small, subtle reset cache button
				Button(action: {
					Task {
						await promptManager.resetCodeMapCache()
					}
				}) {
					HStack(spacing: 2) {
						Image(systemName: "arrow.clockwise")
							.font(.system(size: 10 * fontPreset.scaleFactor))
						Text("Reset Cache")
							.font(.system(size: 10 * fontPreset.scaleFactor))
					}
					.foregroundColor(.secondary)
				}
				.buttonStyle(PlainButtonStyle())
				.disabled(isGloballyDisabled)
				.padding(.leading, 3)
				.padding(.vertical, 2)
				.background(Color.gray.opacity(0.1))
				.cornerRadius(16)
				.help("Clear all cached code maps and rescan files")
			}
			Picker("", selection: Binding(
				get: { currentCodeMapUsage },
				set: { newValue in
					// Use wrapper method to auto-switch to Manual mode
					switch context {
					case .copy:
						promptManager.updateCodeMapUsage(newValue)
					case .chat:
						promptManager.updateCodeMapUsageForChat(newValue)
					}
				}
			)) {
				ForEach(CodeMapUsage.allCases, id: \.self) { usage in
					Text(usage.rawValue.capitalized)
						.font(fontPreset.font)
						.tag(usage)
				}
			}
			.labelsHidden()
			.pickerStyle(SegmentedPickerStyle())
			.disabled(isGloballyDisabled)

			if isGloballyDisabled {
				Text("Effective mode: None (global override). Saved mode: \(currentCodeMapUsage.rawValue.capitalized).")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			} else {
				Text(effectiveCodeMapUsage.caption)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
		}
	}

	// Progress information for incomplete scans
	private var progressInfo: some View {
		VStack(alignment: .leading, spacing: 6 * fontPreset.scaleFactor) {
			ProgressView(value: progressFraction)
				.scaleEffect(fontPreset.scaleFactor)
			HStack {
				Text("Remaining: \(fileManager.remainingScanCount) of \(fileManager.totalFilesSeen)")
					.font(fontPreset.captionFont)
				Spacer()
				if fileManager.remainingScanCount > 0 {
					Button(didRequestScanCancel ? "Cancelling…" : "Cancel Scan") {
						didRequestScanCancel = true
						Task { await promptManager.cancelCodeMapScans() }
					}
					.font(fontPreset.captionFont)
					.buttonStyle(.borderless)
					.disabled(didRequestScanCancel)
				}
			}
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16 * fontPreset.scaleFactor) {
			// Code-map usage controls
			codeMapControls

			// Language legend section
			if !scannedLanguages.isEmpty {
				VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
					Text("Scanned Supported Languages")
						.font(fontPreset.headlineFont)
					languagesLegend
				}
			}

			// Progress or completion info
			if !isComplete || fileManager.remainingScanCount > 0 {
				progressInfo
			} else if isGloballyDisabled {
				Text("Code Maps disabled globally")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			} else {
				Text("\(tokenCounter.cachedFileAPIs.count) supported files scanned")
					.font(fontPreset.captionFont)
			}
		}
		.onChange(of: fileManager.remainingScanCount) { _, remaining in
			if remaining == 0 {
				didRequestScanCancel = false
			}
		}
	}
}
