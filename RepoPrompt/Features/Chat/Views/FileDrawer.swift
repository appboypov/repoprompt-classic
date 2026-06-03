import SwiftUI

// MARK: - Model Name Truncation Helper
extension String {
	static func truncateModelName(_ text: String, maxLength: Int = 40) -> String {
		// If it's within the limit, return as is
		if text.count <= maxLength {
			return text
		}
		
		// Try removing everything before the last "/"
		if let lastSlashIndex = text.lastIndex(of: "/") {
			let trimmedText = String(text[lastSlashIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			if trimmedText.count <= maxLength {
				return trimmedText
			}
		}
		
		// Fallback: Just truncate from the head
		let startIndex = text.index(text.endIndex, offsetBy: -maxLength)
		return "…\(text[startIndex...])"
	}
}

private enum ChatDrawerMetrics {
	static let controlHeight: CGFloat = 28
	static let rowVerticalPadding: CGFloat = 4
	static let controlSpacing: CGFloat = 8
	static let modelAreaMinWidth: CGFloat = 180
}

private extension ChatDrawerMetrics {
	static let sectionSpacing: CGFloat = 0
	static let leftAnchorMinWidth: CGFloat = 140
}

struct SelectedFilesDrawer: View {
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	let windowID: Int
	
	@Binding var showSettingsPopover: Bool
	@Binding var showStoredPrompts: Bool
	@Binding var showPromptSettingsPopover: Bool
	
	// Access the font scale manager
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	// State for popovers
	@State private var showSelectedFilesPopover = false
	@State private var showContextPopover = false
	
	// MARK: - Token texts
	/// First part: estimate for next prompt, always shown
	private var upcomingInputText: String {
		viewModel.upcomingInputTokenText
	}
	/// Second part: total tokens consumed so far in chat
	private var chatTotalText: String {
		viewModel.tokenDisplayText
	}
	
	// MARK: - Mode helpers
	private var currentPreset: ChatPreset {
		promptViewModel.currentChatPreset()
	}
	private var isManualMode: Bool {
		currentPreset.id == ChatPreset.BuiltIn.manual.id
	}
	private var isReviewMode: Bool {
		currentPreset.id == ChatPreset.BuiltIn.reviewUUID
	}
	
	// MARK: - Body
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			contextHeader
			Divider()
			
			// Single-line compact control bar with context + info
			primaryControlBar
		}
		.background(Color(NSColor.systemGray).opacity(0.1))
	}
}

private extension SelectedFilesDrawer {
	
	// Settings button with progressive disclosure popover
	var settingsButton: some View {
		let preset = promptViewModel.currentChatPreset()
		let isManual = preset.id == ChatPreset.BuiltIn.manual.id
		
		// Check if there are any active/unlocked controls
		let hasActiveControls: Bool = {
			if isManual {
				// In manual mode, check if any controls are actually enabled
				return promptViewModel.fileTreeOption != .none ||
					promptViewModel.codeMapUsage != .none ||
					promptViewModel.gitViewModel.gitDiffInclusionMode != .none
			} else {
				// In preset mode, only active if git is unlocked (like Review mode)
				if let gitInclusion = preset.gitInclusion {
					return gitInclusion != .none
				}
				return false
			}
		}()
		
		return Button {
			showContextPopover.toggle()
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "gearshape")
					.fixedSize()
				Text("Controls")
					.lineLimit(1)
					.truncationMode(.tail)
			}
			.font(fontPreset.standardFont)
		}
		.buttonStyle(CustomButtonStyle(isPresetActive: hasActiveControls))
		.hoverTooltip(isManualMode
			? "Configure context settings for this chat\nFile tree, code maps, and git options"
			: "Adjust context settings\nChanges switch to Manual mode")
		.popover(isPresented: $showContextPopover, arrowEdge: .bottom) {
			ContextControlsPopover(
				promptViewModel: promptViewModel,
				isManualMode: isManualMode,
				isReviewMode: isReviewMode
			)
			.padding()
		}
	}
	
	
	// Override badge when model is dictated by preset; otherwise dropdown
	var modelSelectorOrBadge: some View {
		// Keep the original first line for stable anchoring
		let hasModelOverride = ChatPresetManager.shared
			.resolvedPreset(with: currentPreset.id)?
			.modelPresetName != nil
		
		let state: ModelControlState
		if viewModel.mcpModelInfo != nil {
			let display = String.truncateModelName(
				viewModel.mcpOverrideModelName ?? promptViewModel.preferredAIModel.displayName
			)
			state = .mcp(displayName: display)
		} else if hasModelOverride,
					let modelName = ChatPresetManager.shared
					.resolvedPreset(with: currentPreset.id)?
					.modelPresetName,
					let model = AIModel.fromModelName(modelName) {
			state = .presetOverride(
				displayName: String.truncateModelName(model.displayName),
				presetName: currentPreset.name
			)
		} else {
			state = .dropdown
		}
		
		return ModelAreaView(
			state: state,
			promptViewModel: promptViewModel,
			showSettingsPopover: $showSettingsPopover,
			windowID: windowID
		)
	}
	
	
	var contextHeader: some View {
		HStack(spacing: 6) {
			Text("Context")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
			Text(activeTabName)
				.font(fontPreset.subheadlineFont)
				.foregroundColor(.primary)
			Text("•")
				.foregroundColor(.secondary)
			Text(activeSessionName)
				.font(fontPreset.subheadlineFont)
				.foregroundColor(.secondary)
				.lineLimit(1)
			Spacer()
		}
		.padding(.horizontal)
		.padding(.top, fontPreset.scaledMetric(ChatDrawerMetrics.rowVerticalPadding))
	}
	
	// Primary control row - single line layout (includes context and info)
	var primaryControlBar: some View {
		HStack(spacing: fontPreset.scaledMetric(ChatDrawerMetrics.controlSpacing)) {
		
			selectedFilesButton
			PromptsButton(
				showStoredPrompts: $showStoredPrompts,
				promptViewModel: promptViewModel
			)
			settingsButton

			Spacer()
			
			tokenReadout
			
			Spacer()
			
			// Right cluster: Model | Token Readout
			modelSelectorOrBadge
			
			// Left cluster: Preset | Files | Prompts | Settings
			ChatPresetPickerButton(
				promptViewModel: promptViewModel,
				mcpModelInfo: viewModel.mcpModelInfo,
				mcpOverrideChatPresetName: viewModel.mcpOverrideChatPresetName
			)
		}
		.padding(.horizontal)
		.padding(.top, fontPreset.scaledMetric(ChatDrawerMetrics.rowVerticalPadding))
		.padding(.bottom, fontPreset.scaledMetric(ChatDrawerMetrics.rowVerticalPadding + 2))
	}

	var activeTabName: String {
		guard let activeID = promptViewModel.activeComposeTabID,
			let tab = promptViewModel.currentComposeTabs.first(where: { $0.id == activeID }) else {
			return "Tab"
		}
		return tab.name
	}

	var activeSessionName: String {
		viewModel.currentSession?.name ?? "New Chat"
	}
	
	
	// Compact token readout
	var tokenReadout: some View {
		HStack(spacing: 4) {
			Text(upcomingInputText)
				.font(fontPreset.captionFont)
				.foregroundColor(tokenWarningColor(promptViewModel))
				.hoverTooltip("Estimated tokens for the next prompt you will send.")
				.lineLimit(1)
				.truncationMode(.head)
			if !chatTotalText.isEmpty {
				Text("|").foregroundColor(.secondary)
				Text(chatTotalText)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.hoverTooltip("Accumulated tokens used by this chat session.")
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
	}
	
	// Selected files popover trigger
	var selectedFilesButton: some View {
		let hasSelectedFiles = promptViewModel.hasPromptSnapshotEntriesForChat()
		// Count actual selected files, not how they're rendered (codemap vs full)
		let selectionCount = promptViewModel.fileManager.selectedFiles.count
		
		return Button {
			showSelectedFilesPopover.toggle()
		} label: {
			HStack(spacing: 4) {
				Text("Files")
					.lineLimit(1)
					.foregroundColor(.primary)
				
				Text("(\(selectionCount))")
					.foregroundColor(.secondary)
					.font(fontPreset.captionFont)
			}
		}
		.buttonStyle(SelectorButtonStyle(hasSelection: hasSelectedFiles))
		.hoverTooltip("Show selected files", .top)
		.popover(isPresented: $showSelectedFilesPopover) {
			let promptEntries = promptViewModel.promptSnapshotEntriesForChatCached()
			SelectedFilesGrid(
				entries: promptEntries,
				fileManager: promptViewModel.fileManager,
				onRemove: { entry in
					if entry.isCodemap {
						if promptViewModel.fileManager.isAutoCodemapFile(entry.file) {
							promptViewModel.fileManager.removeCodemapFile(entry.file)
						} else {
							promptViewModel.fileManager.toggleFile(entry.file)
						}
					} else {
						promptViewModel.fileManager.toggleFile(entry.file)
					}
				}
			)
			.frame(width: fontPreset.scaledClamped(420, max: 560))
			.frame(
				minHeight: fontPreset.scaledMetric(200),
				idealHeight: min(
					fontPreset.scaledClamped(500, max: 660),
					fontPreset.scaledMetric(CGFloat(max(selectionCount, 1)) * 40 + 100)
				),
				maxHeight: fontPreset.scaledClamped(600, max: 760)
			)
		}
	}
	
	
	// Token warning color logic
	func tokenWarningColor(_ promptModel: PromptViewModel) -> Color {
		if promptModel.totalTokenCountWithDiff > 20000 {
			return .orange
		}
		return .secondary
	}
}

// MARK: - Context Controls Popover
struct ContextControlsPopover: View {
	// This avoids stale 'isManualMode' captured at creation time causing inconsistent state during toggle.
	@ObservedObject var promptViewModel: PromptViewModel
	let isManualMode: Bool       // kept for API compatibility; not used directly anymore
	let isReviewMode: Bool       // kept for API compatibility; continue to read current preset below if needed

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	@State private var showProEditSettings = false

	// Use persisted values from PromptViewModel instead of transient @State

	private var currentPreset: ChatPreset {
		promptViewModel.currentChatPreset()
	}
	// NEW: Live mode resolution (authoritative)
	private var resolvedIsManualMode: Bool {
		currentPreset.id == ChatPreset.BuiltIn.manual.id
	}

	// Computed property so it updates reactively when planActMode changes
	private var canUseProEdit: Bool {
		promptViewModel.planActMode == .edit && resolvedIsManualMode
	}

	var body: some View {
		VStack(spacing: 8) {
			// CONTEXT header
			VStack(alignment: .leading, spacing: 6) {
				Text("CONTEXT")
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(.secondary)
					.padding(.horizontal, 8)

				// Preset/manual toggle banner – uses live mode flag
				HStack(spacing: 6) {
					Button {
						showProEditSettings = false

						if resolvedIsManualMode {
							if let id = promptViewModel.lastNonManualChatPresetID,
								let preset = ChatPresetManager.shared.preset(with: id) {
								promptViewModel.applyChatPreset(preset)
							} else {
								let fallbackPreset = ChatPreset.BuiltIn.edit
								promptViewModel.applyChatPreset(fallbackPreset)
								promptViewModel.MarkDirty()
							}
						} else {
							// No need to set here; applyChatPreset(manual)
							// will persist the current preset as "lastNonManual".
							promptViewModel.applyChatPreset(ChatPreset.BuiltIn.manual)
							promptViewModel.MarkDirty()
						}
					} label: {
						HStack(spacing: 6) {
							Image(systemName: "wand.and.stars")
								.font(fontPreset.swiftUIFont(sizeAtNormal: 11))
							if resolvedIsManualMode {
								if promptViewModel.lastNonManualChatPresetName.isEmpty {
									Text("Manual Mode • Restore previous preset")
										.font(fontPreset.standardFont)
										.foregroundColor(.primary)
										.lineLimit(1)
										.truncationMode(.tail)
								} else {
									Text("Manual Mode • Restore \(promptViewModel.lastNonManualChatPresetName)")
										.font(fontPreset.standardFont)
										.foregroundColor(.primary)
										.lineLimit(1)
										.truncationMode(.tail)
								}
							} else {
								Text("Preset Active • \(currentPreset.name)")
									.font(fontPreset.standardFont)
									.foregroundColor(.primary)
									.lineLimit(1)
									.truncationMode(.tail)
							}
							Image(systemName: "chevron.right")
								.font(fontPreset.swiftUIFont(sizeAtNormal: 10))
								.foregroundColor(.secondary)
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 5)
						.background(resolvedIsManualMode ? Color.gray.opacity(0.10) : Color.blue.opacity(0.10))
						.cornerRadius(8)
						.overlay(
							RoundedRectangle(cornerRadius: 8)
								.stroke((resolvedIsManualMode ? Color.gray.opacity(0.5) : Color.blue.opacity(0.5)), lineWidth: 1)
						)
					}
					.buttonStyle(.plain)
					.hoverTooltip(resolvedIsManualMode
									? "Click to restore the previously active preset"
									: "Preset '\(currentPreset.name)' is active\nChanging a setting switches to Manual mode")

					Spacer(minLength: 0)
				}
				.padding(.horizontal, 8)

				// Controls row – updates switch to Manual while preserving current settings
				HStack(alignment: .top, spacing: 6) {
					// File tree
					FileTreePrefTag(
						promptManager: promptViewModel,
						context: .chat
					)
	
					// Scan
					ScanFilesPrefTag(
						fileManager: promptViewModel.fileManager,
						promptManager: promptViewModel,
						context: .chat,
						isChatContext: true
					)
	
					// Git
					GitPrefTag(
						gitViewModel: promptViewModel.gitViewModel,
						promptManager: promptViewModel,
						context: .chat,
						gitDiffTokenCount: promptViewModel.gitDiffTokenCount
					)
	
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 8)
				.padding(.bottom, 4)
			}

			Divider()
				.padding(.horizontal, 8)

			// PROMPT MODE section – uses live flag
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("PROMPT MODE")
						.font(fontPreset.captionFont.weight(.medium))
						.foregroundColor(.secondary)
						.padding(.horizontal, 8)

					Picker("", selection: $promptViewModel.planActMode) {
						Text("Chat").tag(PromptViewModel.PlanActMode.chat)
						Text("Plan").tag(PromptViewModel.PlanActMode.plan)
						Text("Edit").tag(PromptViewModel.PlanActMode.edit)
						Text("Review").tag(PromptViewModel.PlanActMode.review)
					}
					.labelsHidden()
					.pickerStyle(.segmented)
					.padding(.horizontal, 8)
					.disabled(!resolvedIsManualMode)
					.opacity(resolvedIsManualMode ? 1.0 : 0.6)

					Spacer()
				}

				HStack(spacing: 6) {
					Toggle(isOn: $promptViewModel.proFileEdits) {
						Text("Pro Edit")
							.font(fontPreset.standardFont)
					}
					.toggleStyle(.switch)
					.controlSize(.small)

					Spacer()

					Button(action: {
						if canUseProEdit {
							showProEditSettings = true
						}
					}) {
						HStack(spacing: 4) {
							Image(systemName: "gearshape.fill")
								.font(fontPreset.standardFont)
							Text("Configure")
								.font(fontPreset.standardFont)
						}
					}
					.buttonStyle(CustomButtonStyle())
					.popover(isPresented: $showProEditSettings) {
						ScrollView {
							ProEditSettingsView(promptViewModel: promptViewModel)
								.frame(width: fontPreset.scaledClamped(475, max: 620))
								.padding(8)
						}
					}
				}
				.padding(.horizontal, 8)
				.padding(.top, 8)
				.disabled(!canUseProEdit)
				.opacity(canUseProEdit ? 1.0 : 0.55)
			}
		}
		.padding(.vertical, 8)
	}
}

// MARK: - Selected Files Grid View
struct SelectedFilesGrid: View {
	enum FileDisplayKind: Int {
		case codemap = 0
		case slices = 1
		case full = 2
		
		var iconName: String {
			switch self {
			case .codemap: return "square.grid.2x2"
			case .slices: return "scissors"
			case .full: return "doc.text"
			}
		}
		
		var accentColor: Color {
			switch self {
			case .codemap: return Color.purple
			case .slices: return Color.orange
			case .full: return Color.accentColor
			}
		}
		
		func badgeText(for entry: PromptFileEntry) -> String? {
			switch self {
			case .codemap:
				return "Codemap"
			case .slices:
				let count = entry.ranges?.count ?? 0
				return count > 0 ? "Slices ×\(count)" : "Slices"
			case .full:
				return nil
			}
		}
	}
	
	let entries: [PromptFileEntry]
	let fileManager: RepoFileManagerViewModel
	let onRemove: (PromptFileEntry) -> Void
	
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private var sortedEntries: [(entry: PromptFileEntry, kind: FileDisplayKind)] {
		let computed = entries.map { entry -> (PromptFileEntry, FileDisplayKind) in
			let kind: FileDisplayKind
			if entry.isCodemap {
				kind = .codemap
			} else if let ranges = entry.ranges, !ranges.isEmpty {
				kind = .slices
			} else {
				kind = .full
			}
			return (entry, kind)
		}
		
		return computed.sorted { lhs, rhs in
			if lhs.1 != rhs.1 {
				return lhs.1.rawValue < rhs.1.rawValue
			}
			let leftName = lhs.0.file.nameSortKey
			let rightName = rhs.0.file.nameSortKey
			if leftName != rightName {
				return leftName < rightName
			}
			if lhs.0.file.name != rhs.0.file.name {
				return lhs.0.file.name < rhs.0.file.name
			}
			let leftPath = lhs.0.file.uniqueRelativePathSortKey
			let rightPath = rhs.0.file.uniqueRelativePathSortKey
			if leftPath != rightPath {
				return leftPath < rightPath
			}
			return lhs.0.file.uniqueRelativePath < rhs.0.file.uniqueRelativePath
		}
	}
	
	var body: some View {
		let fileItems = sortedEntries.filter { $0.kind != .codemap }
		let codemapItems = sortedEntries.filter { $0.kind == .codemap }
		
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center) {
				Text("Prompt Files")
					.font(fontPreset.standardFont.weight(.medium))
					.foregroundColor(.primary)
				
				Circle()
					.fill(Color.secondary.opacity(0.3))
					.frame(width: 4, height: 4)
				
				Text("\(fileItems.count)")
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(.secondary)
				
				Spacer()
				
				Button {
					Task {
						await fileManager.clearSelection(persistWorkspace: true)
					}
				} label: {
					HStack(spacing: 4) {
						Image(systemName: "xmark.circle")
							.font(fontPreset.swiftUIFont(sizeAtNormal: 11))
						Text("Clear All")
							.font(fontPreset.captionFont)
					}
				}
				.buttonStyle(
					CustomButtonStyle(
						verticalPadding: 3,
						horizontalPadding: 8
					)
				)
				.disabled(entries.isEmpty)
				.help(entries.isEmpty ? "No files to clear" : "Remove all selected files and codemaps")
			}
			
			Divider()
				.padding(.vertical, 2)
			
			tabSwitcher(filesCount: fileItems.count, codemapsCount: codemapItems.count)
			
			if entries.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "doc.text")
						.font(.system(size: 36))
						.foregroundColor(.secondary.opacity(0.4))
					Text("No files selected")
						.font(fontPreset.standardFont)
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				let activeItems = activeTab == .files ? fileItems : codemapItems
				if activeItems.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: activeTab == .files ? "doc.text" : "square.grid.2x2")
							.font(.system(size: 32))
							.foregroundColor(.secondary.opacity(0.4))
						Text(activeTab == .files ? "No files in prompt" : "No codemaps in prompt")
							.font(fontPreset.standardFont)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView(.vertical, showsIndicators: true) {
						LazyVStack(alignment: .leading, spacing: 8) {
							ForEach(Array(activeItems.enumerated()), id: \.element.entry.file.id) { index, element in
								PromptFileTagRow(
									entry: element.entry,
									kind: element.kind,
									onRemove: onRemove,
									rowIndex: index
								)
							}
						}
						.padding(.trailing, 4)
					}
					.frame(maxHeight: .infinity)
				}
			}
		}
		.padding(8)
		.onAppear {
			adjustActiveTab(fileCount: fileItems.count, codemapCount: codemapItems.count)
		}
		.onChange(of: fileItems.count) { newValue in
			adjustActiveTab(fileCount: newValue, codemapCount: codemapItems.count)
		}
		.onChange(of: codemapItems.count) { newValue in
			adjustActiveTab(fileCount: fileItems.count, codemapCount: newValue)
		}
	}
	
	@State private var activeTab: Tab = .files
	
	enum Tab {
		case files
		case codemaps
	}
	
	@State private var hoveredTab: Tab?
	
	@ViewBuilder
	private func tabSwitcher(filesCount: Int, codemapsCount: Int) -> some View {
		HStack(spacing: 0) {
			tabButton(icon: "doc.text", label: "Files", count: filesCount, tab: .files) {
				activeTab = .files
			}
			
			tabButton(icon: "square.grid.2x2", label: "Codemaps", count: codemapsCount, tab: .codemaps) {
				activeTab = .codemaps
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, -12)
		.padding(.vertical, -6)
	}
	
	@ViewBuilder
	private func tabButton(
		icon: String,
		label: String,
		count: Int,
		tab: Tab,
		action: @escaping () -> Void
	) -> some View {
		let isActive = activeTab == tab
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: icon)
					.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
				Text(label)
					.font(fontPreset.captionFont.weight(.semibold))
				Text("\(count)")
					.font(fontPreset.captionFont.weight(.medium))
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, minHeight: 34)
			.background(
				hoveredTab == tab && !isActive
					? Color.primary.opacity(0.08)
					: Color.clear
			)
			.foregroundColor(
				isActive
					? Color.accentColor
					: (hoveredTab == tab ? Color.primary : Color.secondary)
			)
			.overlay(alignment: .bottom) {
				Rectangle()
					.fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
					.frame(height: isActive ? 2 : 1)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(isActive)
		.onHover { hovering in
			hoveredTab = hovering ? tab : nil
		}
	}
	
	private func adjustActiveTab(fileCount: Int, codemapCount: Int) {
		if activeTab == .files && fileCount == 0 && codemapCount > 0 {
			activeTab = .codemaps
		} else if activeTab == .codemaps && codemapCount == 0 && fileCount > 0 {
			activeTab = .files
		}
	}
}

struct PromptFileTagRow: View {
	let entry: PromptFileEntry
	let kind: SelectedFilesGrid.FileDisplayKind
	let onRemove: (PromptFileEntry) -> Void
	let rowIndex: Int
	
	@State private var showPopover = false
	@State private var hoveringPreview = false
	@State private var hoveringCopy = false
	@State private var hoveringRemove = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private var accentColor: Color { kind.accentColor }
	
	private var directoryDisplay: String? {
		let unique = entry.file.uniqueRelativePath
		if let lastSlash = unique.lastIndex(of: "/") {
			let directory = String(unique[..<lastSlash])
			if !directory.isEmpty {
				return directory
			}
		}
		let root = entry.file.rootFolderName
		return root.isEmpty ? nil : root
	}
	
	var body: some View {
		HStack(spacing: 12) {
			RoundedRectangle(cornerRadius: 2)
				.fill(accentColor.opacity(0.65))
				.frame(width: 4, height: 32)
			
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Image(systemName: kind.iconName)
						.foregroundColor(accentColor)
						.font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
					
					Text(entry.file.name)
						.font(fontPreset.standardFont.weight(.semibold))
						.foregroundColor(.primary)
						.lineLimit(1)
						.truncationMode(.tail)
					
					if let badge = kind.badgeText(for: entry) {
						Text(badge)
							.font(fontPreset.captionFont.bold())
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(accentColor.opacity(0.15))
							.foregroundColor(accentColor)
							.cornerRadius(6)
					}
					
					Spacer(minLength: 0)
				}
				
				if let directory = directoryDisplay {
					Text(directory)
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			
			Spacer(minLength: 0)
			
			HStack(spacing: 6) {
				Button {
					showPopover = true
				} label: {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 13, weight: .medium))
						.foregroundColor(hoveringPreview ? accentColor : .primary)
						.padding(6)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(hoveringPreview ? accentColor.opacity(0.12) : Color.clear)
						)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Preview File")
				.onHover { hoveringPreview = $0 }
				
				Button(action: copyToClipboard) {
					Image(systemName: "doc.on.clipboard")
						.font(.system(size: 13, weight: .medium))
						.foregroundColor(hoveringCopy ? accentColor : .primary)
						.padding(6)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(hoveringCopy ? accentColor.opacity(0.12) : Color.clear)
						)
				}
				.buttonStyle(.plain)
				.hoverTooltip(kind == .codemap ? "Copy Codemap" : "Copy File Content")
				.onHover { hoveringCopy = $0 }
				
				Button {
					onRemove(entry)
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 13, weight: .medium))
						.foregroundColor(hoveringRemove ? Color.red : .secondary)
						.padding(6)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(hoveringRemove ? Color.red.opacity(0.12) : Color.clear)
						)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Remove")
				.onHover { hoveringRemove = $0 }
			}
			.padding(.horizontal, 4)
			.padding(.vertical, 3)
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(Color.primary.opacity(0.06))
			)
			.frame(minWidth: 90, alignment: .trailing)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 8)
		.background(
			rowIndex % 2 == 0
				? Color(NSColor.controlBackgroundColor).opacity(0.24)
				: Color(NSColor.controlBackgroundColor).opacity(0.14)
		)
		.cornerRadius(8)
		.contentShape(Rectangle())
		.popover(isPresented: $showPopover, arrowEdge: .bottom) {
			FilePreviewPopover(
				file: entry.file,
				fileSlices: entry.ranges,
				showCodeMap: entry.isCodemap,
				showPreview: $showPopover
			)
		}
	}
	
	private func copyToClipboard() {
		NSPasteboard.general.clearContents()
		if entry.isCodemap {
			let codemap = entry.file.fileAPI?.getFullAPIDescription(displayPath: entry.file.uniqueRelativePath) ?? ""
			NSPasteboard.general.setString(codemap, forType: .string)
		} else if let content = entry.file.cachedContent {
			NSPasteboard.general.setString(content, forType: .string)
		} else {
			NSPasteboard.general.setString("", forType: .string)
		}
	}
}

struct ExtraFilesCounter: View {
	let count: Int
	
	var body: some View {
		Text("+\(count)")
			.foregroundColor(.secondary)
			.padding(.horizontal, 12)
			.padding(.vertical, 5)
			.background(Color.secondary.opacity(0.1))
			.cornerRadius(8)
	}
}

struct PromptsButton: View {
	@Binding var showStoredPrompts: Bool
	@ObservedObject var promptViewModel: PromptViewModel
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private var totalPromptCount: Int {
		let currentChat = promptViewModel.currentChatPreset()

		// Count stored prompts from preset, but exclude system-stored prompts
		// (when useStoredPromptsAsSystem is true with exactly one stored prompt,
		// that prompt is used as the system prompt and shouldn't appear in the count)
		var identifiers = Set(promptViewModel.selectedPromptIDsForChat)
		if let presetIds = currentChat.storedPromptIds {
			let isSystemStoredPrompt = (currentChat.useStoredPromptsAsSystem ?? false) && presetIds.count == 1
			if !isSystemStoredPrompt {
				identifiers.formUnion(presetIds)
			}
		}

		return identifiers.count
	}
	
	private var modeColor: Color {
		if promptViewModel.proFileEdits && promptViewModel.planActMode == .edit {
			return .orange // Pro Edit
		}
		switch promptViewModel.planActMode {
		case .chat:
			return .blue
		case .plan:
			return .purple
		case .edit:
			return .green
		case .review:
			return .teal
		}
	}
	
	private var modeLabel: String {
		if promptViewModel.proFileEdits && promptViewModel.planActMode == .edit {
			return "Pro"
		}
		switch promptViewModel.planActMode {
		case .chat:
			return "Chat"
		case .plan:
			return "Plan"
		case .edit:
			return "Edit"
		case .review:
			return "Review"
		}
	}

	var body: some View {
		let hasSelectedPrompts = totalPromptCount > 0
		return Button(action: {
			showStoredPrompts.toggle()
		}) {
			HStack(spacing: 4) {
				// Mode indicator pill
				Text(modeLabel)
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(modeColor)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.background(
						Capsule()
							.fill(modeColor.opacity(0.15))
					)
				
				Text("Prompts")
					.lineLimit(1)
					.foregroundColor(.primary)
				Text("(\(totalPromptCount))")
					.foregroundColor(.secondary)
					.font(fontPreset.captionFont)
					.lineLimit(1)
			}
		}
		.buttonStyle(SelectorButtonStyle(hasSelection: hasSelectedPrompts))
		.hoverTooltip("System prompt: \(modeLabel)", .top)
		.popover(isPresented: $showStoredPrompts) {
			StoredPromptsOverlay(
				isVisible: $showStoredPrompts,
				context: .chat,
				promptManager: promptViewModel
			)
		}
	}
}

// MARK: - Chat Preset Picker Button

struct ChatPresetPickerButton: View {
	@ObservedObject var promptViewModel: PromptViewModel
	let mcpModelInfo: String?
	let mcpOverrideChatPresetName: String?
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	@State private var showPresetPicker = false
	
	private var isManualMode: Bool {
		promptViewModel.currentChatPreset().id == ChatPreset.BuiltIn.manual.id
	}
	
	var body: some View {
		if mcpModelInfo != nil {
			let name = mcpOverrideChatPresetName ?? promptViewModel.currentChatPreset().name
			// MCP-controlled preset: show non-interactive orange chip
			HStack(spacing: 6) {
				Image(systemName: "lock.fill")
					.foregroundColor(.orange)
					.font(fontPreset.standardFont)
					.fixedSize()
				Text("\(name)")
					.font(fontPreset.standardFont)
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.tail)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Color.orange.opacity(0.1))
			.cornerRadius(8)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color.orange.opacity(0.5), lineWidth: 1)
			)
			.hoverTooltip("Preset controlled by MCP")
		} else {
			Button(action: { showPresetPicker = true }) {
				HStack(spacing: 4) {
					Image(systemName: "sparkles")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
						.fixedSize()
					Text(currentPresetName)
						.lineLimit(1)
						.truncationMode(.tail)
						.frame(minWidth: 45, alignment: .leading)
					Image(systemName: "chevron.down")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 10))
						.fixedSize()
				}
			}
			.buttonStyle(CustomButtonStyle(isPresetActive: !isManualMode))
			.hoverTooltip("Select chat preset: \(currentPresetName)\n\(isManualMode ? "Full control over all settings" : "Preset manages context and behavior")")
			.accessibilityLabel("Chat Preset")
			.popover(isPresented: $showPresetPicker) {
				chatPresetPopoverContent()
			}
		}
	}
	
	private var currentPresetName: String {
		if let id = promptViewModel.selectedChatPresetID,
			let preset = ChatPresetManager.shared.preset(with: id) {
			return preset.name
		}
		return "Chat Preset"
	}
	
	@ViewBuilder
	private func chatPresetPopoverContent() -> some View {
		let presetsRaw = ChatPresetManager.shared.allPresets.filter { ChatPresetManager.shared.isPresetVisible($0) }
		let allChatPresets: [ChatPreset] = presetsRaw.isEmpty ? ChatPreset.BuiltIn.all : presetsRaw
		let selectedId = promptViewModel.selectedChatPresetID ?? ChatPreset.BuiltIn.chat.id
		
		PresetTwoPanePopover_Chat(
			allPresets: allChatPresets,
			selectedId: selectedId,
			fontPreset: fontPreset,
			windowID: promptViewModel.windowID,
			promptViewModel: promptViewModel,
			previewBuilder: { preset in
				ChatPresetPreviewView(preset: preset, fontPreset: fontPreset, promptViewModel: promptViewModel)
			},
			onSelect: { preset in
				promptViewModel.applyChatPreset(preset)
				promptViewModel.MarkDirty()
				showPresetPicker = false
			}
		)
		.frame(width: 640 * fontPreset.scaleFactor, height: 436 * fontPreset.scaleFactor)
		.padding(10)
	}
}

// MARK: - Model Control State and View
enum ModelControlState: Equatable {
	case mcp(displayName: String)
	case presetOverride(displayName: String, presetName: String)
	case dropdown
}

struct ModelAreaView: View {
	let state: ModelControlState
	@ObservedObject var promptViewModel: PromptViewModel
	@Binding var showSettingsPopover: Bool
	let windowID: Int

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		switch state {
		case .mcp(let display):
			HStack(spacing: 6) {
				Image(systemName: "lock.fill")
					.foregroundColor(.orange)
					.font(fontPreset.captionFont)
					.fixedSize()
				Text(String.truncateModelName(display))
					.font(fontPreset.captionFont)
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.head)
			}
			.padding(.vertical, 5)
			.padding(.horizontal, 10)
			.background(Color.orange.opacity(0.10))
			.cornerRadius(6)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Color.orange.opacity(0.5), lineWidth: 1)
			)
			.hoverTooltip("Model controlled by MCP")

		case .presetOverride(let display, let presetName):
			HStack(spacing: 6) {
				Image(systemName: "lock.fill")
					.foregroundColor(.secondary)
					.font(fontPreset.captionFont)
					.fixedSize()
				Text(String.truncateModelName(display))
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary.opacity(0.8))
					.lineLimit(1)
					.truncationMode(.head)
			}
			.padding(.vertical, 5)
			.padding(.horizontal, 10)
			.background(Color.secondary.opacity(0.10))
			.cornerRadius(6)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Color.secondary.opacity(0.5), lineWidth: 1)
			)
			.hoverTooltip("Model set by \(presetName) preset")

		case .dropdown:
			AIModelDropdown(
				promptViewModel: promptViewModel,
				showSettingsPopover: $showSettingsPopover,
				windowID: windowID
			)
		}
	}
}
