import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

struct InstructionsView: View {
	@ObservedObject var promptManager: PromptViewModel
	var onSendToChat: (() -> Void)? = nil
	let windowID: Int

	// Experimental toggle: whether to use AttributedTextKitView or legacy TextKitView
	@AppStorage("experimentalAttributedTextEditor") private var experimentalAttributedTextEditor: Bool = false

	// Collapsed state for the instructions view
	// Default is false (expanded)
	@AppStorage("instructionsViewCollapsed") private var isCollapsed: Bool = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	// Height when collapsed - shows about 5 lines of text
	private var collapsedEditorHeight: CGFloat { 112 * fontPreset.scaleFactor }

	@State private var localText: String = ""
	@State private var isEditing: Bool = false
	/// Used to suppress echo when we write back to the view‑model.
	@State private var isWritingBack: Bool = false
	@State private var externalUpdateTick: Int = 0
	@State private var writeBackDebounceItem: DispatchWorkItem? = nil
	@State private var writeBackWorkGate = WorkItemGate()
	@State private var isCopyingInstructions: Bool = false

	private var placeholderText: String {
		" Task instructions for your prompt. Use context builder to generate automatically..."
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
		HStack {
			// Collapse/expand toggle - clicking chevron or title toggles
			Button(action: {
				// Track that user explicitly set this preference
				UserDefaults.standard.set(true, forKey: "instructionsViewCollapsedUserDidSet")
				withAnimation(.easeInOut(duration: 0.2)) {
					isCollapsed.toggle()
				}
			}) {
				HStack(spacing: 4) {
					Image(systemName: "chevron.down")
						.rotationEffect(.degrees(isCollapsed ? -90 : 0))
						.foregroundColor(.secondary)
						.frame(width: 16, height: 16)

					Text("Instructions")
						.font(fontPreset.subHeadlineBoldFont)
						.foregroundColor(.primary)
				}
			}
			.buttonStyle(.plain)
			.contentShape(Rectangle())
			.hoverTooltip(isCollapsed ? "Expand instructions" : "Collapse instructions")

			// Copy button
			Button(action: {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(localText, forType: .string)
				isCopyingInstructions = true
				DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
					isCopyingInstructions = false
				}
			}) {
				Image(systemName: isCopyingInstructions ? "checkmark" : "doc.on.doc")
					.foregroundColor(localText.isEmpty ? .gray : .secondary)
					.frame(width: 20, height: 20)
			}
			.buttonStyle(PlainButtonStyle())
			.contentShape(Rectangle())
			.disabled(localText.isEmpty)
			.hoverTooltip("Copy instructions text")

			// Clear button
			Button(action: {
				// Clear the bound text and force a programmatic refresh in the editor
				localText = ""
				externalUpdateTick &+= 1
			}) {
				Image(systemName: "xmark.circle.fill")
					.foregroundColor(localText.isEmpty ? .gray : .secondary)
			}
			.buttonStyle(PlainButtonStyle())
			.disabled(localText.isEmpty)
			.hoverTooltip("Clear instructions text")

			Spacer()

			// Send to Chat button
			if let onSendToChat = onSendToChat {
				Button(action: onSendToChat) {
					HStack(spacing: 6) {
						Image(systemName: "wand.and.stars")
						Text("Send to Chat")
					}
					.font(fontPreset.standardFont)
				}
				.buttonStyle(CustomButtonStyle())
				.keyboardShortcut("n", modifiers: [.command, .shift])
				.hoverTooltip("Send the current prompt to chat\n⌘⇧N")
			}
		}
			.padding(.horizontal, 10)
			.frame(height: 40)
			//.background(Color(NSColor.systemGray).opacity(0.1))
			.cornerRadius(10, corners: [.topLeft, .topRight])
			
			Divider()
			
			// Choose which editor to present based on user preference
			Group {
				if experimentalAttributedTextEditor {
					// New rich text editor
					AttributedTextKitView(
						text: $localText,
						isEditable: true,
						isSpellCheckEnabled: promptManager.spellCheckInstructions,
						fontSize: fontPreset.rawValue,
						externalUpdateTick: externalUpdateTick,
						onEditingChanged: { editing in
							isEditing = editing
							if !editing {
								// Commit immediately when editing ends
								writeBackDebounceItem?.cancel()
								writeBackWorkGate.cancel()
								if promptManager.promptText != localText {
									isWritingBack = true
									promptManager.promptText = localText
									isWritingBack = false
								}
							}
						},
						fileManager: promptManager.fileManager
					)
				} else {
					// Legacy plain-text editor
					TextKitView(
						text: $localText,
						isEditable: true,
						isSpellCheckEnabled: promptManager.spellCheckInstructions,
						fontSize: fontPreset.rawValue,
						useMonospacedFont: false,
						wrapLines: true,
						externalUpdateTick: externalUpdateTick,
						onEditingChanged: { editing in
							isEditing = editing
							if !editing {
								// Commit immediately when editing ends
								writeBackDebounceItem?.cancel()
								writeBackWorkGate.cancel()
								if promptManager.promptText != localText {
									isWritingBack = true
									promptManager.promptText = localText
									isWritingBack = false
								}
							}
						}
					)
				}
			}
			// Disable implicit animations in the editor subtree to prevent flicker
			.transaction { $0.disablesAnimations = true }
			// Constrain height when collapsed, expand to fill available space when expanded
			.frame(minHeight: isCollapsed ? collapsedEditorHeight : nil,
				maxHeight: isCollapsed ? collapsedEditorHeight : .infinity)
			.clipped()
			.overlay(
				Text(placeholderText)
					.font(fontPreset.font)
					.foregroundColor(.secondary)
					.opacity(localText.isEmpty ? 1 : 0)
					.padding(10)
					.allowsHitTesting(false)
					.animation(nil, value: localText.isEmpty),
				alignment: .topLeading
			)
			
		}
		.animation(.easeInOut(duration: 0.2), value: isCollapsed)
		.overlay(
			RoundedRectangle(cornerRadius: 16)
				.stroke(Color(NSColor.systemGray), lineWidth: 0.5)
		)
		// Keep local text in sync with model on appear / external changes.
		.onAppear {
			localText = promptManager.promptText
			// Bump tick to ensure TextKitView syncs on appear
			externalUpdateTick &+= 1
		}
		.onChange(of: promptManager.promptText) { _, newValue in
			// Accept external source-of-truth updates unless they originated from this view's writeback.
			if isWritingBack {
				isWritingBack = false
				return
			}
			if newValue != localText {
				localText = newValue
				externalUpdateTick &+= 1
			}
		}
		.onChange(of: localText) { _, value in
			writeBackDebounceItem?.cancel()
			writeBackWorkGate.cancel()
			// If we aren't actively editing, write through immediately (e.g., programmatic changes)
			guard isEditing else {
				if promptManager.promptText != value {
					isWritingBack = true
					promptManager.promptText = value
					isWritingBack = false
				}
				return
			}
			// While the user is typing, coalesce rapid changes
			writeBackDebounceItem = writeBackWorkGate.schedule(after: 0.5) { [value] in
				if promptManager.promptText != value {
					isWritingBack = true
					promptManager.promptText = value
					isWritingBack = false
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .willSwitchComposeTab)) { notification in
			// Only respond to notifications for this window
			guard let notificationWindowID = notification.userInfo?["windowID"] as? Int,
				  notificationWindowID == windowID else {
				return
			}

			// Only flush if there's actually a pending user edit (debounce was active).
			// If writeBackDebounceItem is nil, localText should already be synced from the binding,
			// OR it's stale because SwiftUI's onChange hasn't fired yet after a workspace switch.
			// Flushing stale localText would overwrite the correct value loaded from the new workspace.
			guard let pendingWrite = writeBackDebounceItem else {
				return
			}
			pendingWrite.cancel()
			writeBackDebounceItem = nil
			writeBackWorkGate.cancel()
			if promptManager.promptText != localText {
				isWritingBack = true
				promptManager.promptText = localText
				isWritingBack = false
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .workspaceWillSave)) { notification in
			// Only respond to notifications for this window
			guard let notificationWindowID = notification.userInfo?["windowID"] as? Int,
				  notificationWindowID == windowID else {
				return
			}

			// Only flush if there's actually a pending user edit (debounce was active).
			// If writeBackDebounceItem is nil, localText should already be synced from the binding,
			// OR it's stale because SwiftUI's onChange hasn't fired yet after a workspace switch.
			// Flushing stale localText would overwrite the correct value loaded from the new workspace.
			guard let pendingWrite = writeBackDebounceItem else {
				return
			}
			pendingWrite.cancel()
			writeBackDebounceItem = nil
			writeBackWorkGate.cancel()
			if promptManager.promptText != localText {
				isWritingBack = true
				promptManager.promptText = localText
				isWritingBack = false
			}
		}
		// Note: We don't need .activeComposeTabChanged here because .onChange(of: promptManager.promptText)
		// reliably catches binding updates when the tab switch loads the new tab's data.
	}
}
struct SimplePopoverButton<Content: View>: View {
	@Binding var showPopover: Bool
	let icon: String
	let content: Content
	
	init(showPopover: Binding<Bool>, icon: String, @ViewBuilder content: @escaping () -> Content) {
		self._showPopover = showPopover
		self.icon = icon
		self.content = content()
	}
	
	var body: some View {
		Button(action: {
			showPopover.toggle()
		}) {
			Text("Prompts")
		}
		.buttonStyle(CustomButtonStyle())
		.popover(isPresented: $showPopover, arrowEdge: .bottom) {
			content
		}
	}
}

struct StoredPromptsOverlay: View {
	@Binding var isVisible: Bool
	let context: PromptViewModel.PromptSelectionContext
	@ObservedObject var promptManager: PromptViewModel
	@State private var showPromptAuthor = false
	@State private var editingPrompt: PromptViewModel.StoredPrompt?
	@State private var draggedPrompt: PromptViewModel.StoredPrompt?
	@State private var dragTargetIndex: Int?
	@State private var systemPromptSelection: SystemPromptOption = .none
	@State private var editPromptSelection: EditPromptOption = .none
	@State private var showProEditSettings = false
	@State private var isApplyingSelection = false  // Prevent cascade when applying mutual exclusivity
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private var selection: Set<UUID> {
		promptManager.promptSelection(for: context)
	}
	
	private var selectionPublisher: AnyPublisher<Set<UUID>, Never> {
		switch context {
		case .copy:
			return promptManager.$selectedPromptIDs.eraseToAnyPublisher()
		case .chat:
			return promptManager.$selectedPromptIDsForChat.eraseToAnyPublisher()
		}
	}
	
	private var systemPromptIDs: [UUID] {
		[
			promptManager.mcpAgentPromptID,
			promptManager.mcpPairProgramPromptID,
		]
	}
	
	private var builtInPrompts: [PromptViewModel.StoredPrompt] {
		let excluded = Set(systemPromptIDs)
		return promptManager.builtInStoredPrompts.filter { !excluded.contains($0.id) }
	}
	
	private var columnSpacing: CGFloat { 12 * fontPreset.scaleFactor }
	private var panelWidth: CGFloat { 660 * fontPreset.scaleFactor }
	private var panelMaxHeight: CGFloat { 520 * fontPreset.scaleFactor }
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			header
			Divider()
			HStack(alignment: .top, spacing: columnSpacing) {
				builtInColumn
				Divider()
				customColumn
			}
		}
		.padding(16 * fontPreset.scaleFactor)
		.frame(width: panelWidth)
		.frame(maxHeight: panelMaxHeight, alignment: .top)
		.background(Color(NSColor.controlBackgroundColor))
		.cornerRadius(12 * fontPreset.scaleFactor)
		.shadow(radius: 10)
		.onAppear {
			promptManager.loadStoredPrompts()
			promptManager.syncPromptSelectionToPreset(for: context, force: false)
			syncSegmentSelections()
		}
		.onReceive(selectionPublisher) { _ in
			guard !isApplyingSelection else { return }
			syncSegmentSelections()
		}
		.onReceive(promptManager.$workingCopyCustomizations) { _ in
			guard !isApplyingSelection else { return }
			// When customizations change (e.g., restored when switching to Manual), update picker state
			syncSegmentSelections()
		}
		.onChange(of: draggedPrompt) { _, newValue in
			if newValue == nil {
				dragTargetIndex = nil
			}
		}
		.sheet(isPresented: $showPromptAuthor) {
			PromptAuthorOverlay(
				isVisible: $showPromptAuthor,
				editingPrompt: $editingPrompt,
				promptManager: promptManager,
				context: context
			)
		}
	}
	
	private var header: some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Stored Prompts")
					.font(fontPreset.headlineFont.weight(.medium))
				Text("Selections update automatically from the active preset. Adjust below to override.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
			
			Spacer()
			
			HStack(spacing: 8) {
				restoreButton
				newPromptButton
			}
		}
	}
	
	private var builtInColumn: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				if context == .copy {
					systemPromptSection
					editPromptSection
				} else if context == .chat {
					chatModeSection
				}
				
				Text("Built-in Prompts")
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(.secondary)

				if builtInPrompts.isEmpty {
					Text("No built-in prompts found.")
						.font(fontPreset.font)
						.foregroundColor(.secondary)
				} else {
					ForEach(builtInPrompts, id: \.id) { prompt in
						StoredPromptRow(
							prompt: prompt,
							isSelected: selection.contains(prompt.id),
							onToggle: { togglePrompt(prompt) },
							onEdit: { beginEditing(prompt) },
							onDelete: nil,
							allowDelete: false
						)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(width: 260 * fontPreset.scaleFactor, alignment: .leading)
	}
	
	private var systemPromptSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("MCP Behavior Prompt")
				.font(fontPreset.captionFont.weight(.medium))
				.foregroundColor(.secondary)
			
			Picker("MCP Behavior Prompt", selection: $systemPromptSelection) {
				ForEach(SystemPromptOption.availableOptions) { option in
					Text(option.label).tag(option)
				}
			}
			.labelsHidden()
			.onChange(of: systemPromptSelection) { _, newValue in
				guard !isApplyingSelection else { return }
				applySystemPromptSelection(newValue)
			}
			
			Text("MCP-related priming prompts for coding agents.")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
	
	private var editPromptSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("XML Edit Prompt")
				.font(fontPreset.captionFont.weight(.medium))
				.foregroundColor(.secondary)
			
			Picker("XML Edit Prompt", selection: $editPromptSelection) {
				ForEach(EditPromptOption.availableOptions) { option in
					Text(option.label).tag(option)
				}
			}
			.labelsHidden()
			.onChange(of: editPromptSelection) { _, newValue in
				guard !isApplyingSelection else { return }
				applyEditPromptSelection(newValue)
			}
			
			Text("Instructions for external chat apps like ChatGPT or AI Studio.")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
	
	// MARK: - Chat Mode Section
	
	private var chatModeSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("System Prompt")
				.font(fontPreset.captionFont.weight(.medium))
				.foregroundColor(.secondary)
			
			HStack(spacing: 8) {
				Picker("Chat Mode", selection: $promptManager.planActMode) {
					Text("Chat").tag(PromptViewModel.PlanActMode.chat)
					Text("Plan").tag(PromptViewModel.PlanActMode.plan)
					Text("Edit").tag(PromptViewModel.PlanActMode.edit)
					Text("Review").tag(PromptViewModel.PlanActMode.review)
				}
				.labelsHidden()
				.frame(maxWidth: .infinity, alignment: .leading)
				.onChange(of: promptManager.planActMode) { _, _ in
					ensureManualPresetIfNeeded()
				}
				
				Toggle(isOn: $promptManager.proFileEdits) {
					Text("Pro Edit")
						.font(fontPreset.captionFont)
				}
				.toggleStyle(.switch)
				.controlSize(.small)
				.disabled(!canUseProEdit)
				.opacity(canUseProEdit ? 1.0 : 0.55)
				.onChange(of: promptManager.proFileEdits) { _, _ in
					ensureManualPresetIfNeeded()
				}
				
				Button(action: {
					if canUseProEdit {
						showProEditSettings = true
					}
				}) {
					Image(systemName: "gearshape")
						.font(fontPreset.captionFont)
				}
				.buttonStyle(PlainButtonStyle())
				.disabled(!canUseProEdit)
				.opacity(canUseProEdit ? 1.0 : 0.55)
				.help("Pro Edit Settings")
				.popover(isPresented: $showProEditSettings) {
					ScrollView {
						ProEditSettingsView(promptViewModel: promptManager)
							.frame(width: 475)
							.padding(8)
					}
				}
			}
			
			Text(chatModeDescription)
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
	
	private var chatModeDescription: String {
		if promptManager.proFileEdits && promptManager.planActMode == .edit {
			return "Pro Edit: Advanced code editing with parallel file processing."
		}
		switch promptManager.planActMode {
		case .chat:
			return "Chat: General conversation and code exploration."
		case .plan:
			return "Plan: Architecture design and implementation planning."
		case .edit:
			return "Edit: Outputs code changes in XML format for direct application."
		case .review:
			return "Review: Code review with git diff context."
		}
	}
	
	private var canUseProEdit: Bool {
		promptManager.planActMode == .edit
	}

	private var customColumn: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text("Custom Prompts")
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(.secondary)
				
				if promptManager.customStoredPrompts.isEmpty {
					Text("Create prompts to reuse frequently used guidance or checklists.")
						.font(fontPreset.font)
						.foregroundColor(.secondary)
						.padding(.vertical, 8)
				} else {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(Array(promptManager.customStoredPrompts.enumerated()), id: \.element.id) { offset, prompt in
							let globalIndex = promptManager.storedPrompts.firstIndex(where: { $0.id == prompt.id }) ?? offset
							
							VStack(spacing: 0) {
								if dragTargetIndex == globalIndex {
									Rectangle()
										.fill(Color.blue.opacity(0.2))
										.frame(height: 2)
										.padding(.vertical, 4)
										.transition(.opacity.combined(with: .slide))
								}
								
						StoredPromptRow(
							prompt: prompt,
							isSelected: selection.contains(prompt.id),
							onToggle: { togglePrompt(prompt) },
							onEdit: { beginEditing(prompt) },
							onDelete: { removePrompt(prompt) }
						)
								.onDrag {
									draggedPrompt = prompt
									return NSItemProvider(object: prompt.id.uuidString as NSString)
								}
						.onDrop(
							of: [UTType.text],
							delegate: PromptDropDelegate(
								currentPrompt: prompt,
								prompts: $promptManager.storedPrompts,
								draggedPrompt: $draggedPrompt,
								promptManager: promptManager,
								dragTargetIndex: $dragTargetIndex,
								currentIndex: globalIndex,
								context: context
							)
						)
							}
						}
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
	
	private var restoreButton: some View {
		Button("Restore") {
			let alert = NSAlert()
			alert.messageText = "Restore Built-In Prompts"
			alert.informativeText = "Architect, Engineer, MCP, and Review prompts will be restored to their default content. Custom prompts stay untouched."
			alert.alertStyle = .warning
			alert.addButton(withTitle: "Restore")
			alert.addButton(withTitle: "Cancel")
			alert.buttons.first?.keyEquivalent = "\r"
			NSApp.activate(ignoringOtherApps: true)
			if let window = NSApp.keyWindow ?? NSApplication.shared.mainWindow {
				alert.beginSheetModal(for: window) { response in
					if response == .alertFirstButtonReturn {
						promptManager.resetBuiltInPrompts()
						promptManager.syncPromptSelectionToPreset(for: context, force: false)
					}
				}
			} else if alert.runModal() == .alertFirstButtonReturn {
				promptManager.resetBuiltInPrompts()
				promptManager.syncPromptSelectionToPreset(for: context, force: false)
			}
		}
		.buttonStyle(CustomButtonStyle())
	}
	
	private var newPromptButton: some View {
		Button("New") {
			beginEditing(nil)
		}
		.buttonStyle(CustomButtonStyle())
	}
	

	private func ensureManualPresetIfNeeded() {
		promptManager.ensureManualPresetFor(context: context)
	}
	
	private func togglePrompt(_ prompt: PromptViewModel.StoredPrompt) {
		ensureManualPresetIfNeeded()
		promptManager.togglePromptSelection(prompt, in: context)
	}
	
private func removePrompt(_ prompt: PromptViewModel.StoredPrompt) {
	ensureManualPresetIfNeeded()
	promptManager.removeStoredPrompt(prompt)
}

private func beginEditing(_ prompt: PromptViewModel.StoredPrompt?) {
	ensureManualPresetIfNeeded()
	editingPrompt = prompt
	showPromptAuthor = true
}
	
private func applySystemPromptSelection(_ option: SystemPromptOption) {
	isApplyingSelection = true
	
	// Only switch to Manual if user is deviating from the current preset
	let config = resolvedPresetConfiguration()
	let currentOption = SystemPromptOption.option(for: config?.systemPromptFlavor)
	if option != currentOption {
		ensureManualPresetIfNeeded()
	}
	promptManager.applySystemPromptOverride(option.systemPromptFlavor, for: context)
	
	// When setting an MCP mode, clear any XML format to maintain mutual exclusivity
	if option != .none {
		promptManager.applyXMLFormatOverride(nil, for: context)
	}
	
	syncSegmentSelections()
	
	// Delay resetting flag to allow SwiftUI's onChange handlers to complete
	Task { @MainActor in
		isApplyingSelection = false
	}
}

	private func applyEditPromptSelection(_ option: EditPromptOption) {
		isApplyingSelection = true
		
		// Only switch to Manual if user is deviating from the current preset
		let config = resolvedPresetConfiguration()
		let resolvedFormat = config?.xmlFormat
		let currentOption = EditPromptOption.option(for: resolvedFormat)
		if option != currentOption {
			ensureManualPresetIfNeeded()
		}
		let normalizedOption = option
		if editPromptSelection != normalizedOption {
			editPromptSelection = normalizedOption
		}
		
		let targetFormat: ApplyPromptFormat?
		let systemFlavor: SystemPromptFlavor?
		switch normalizedOption {
		case .none:
			targetFormat = nil
			systemFlavor = nil
		case .edit:
			targetFormat = .diff
			systemFlavor = .codeEditDiff
		case .editWhole:
			targetFormat = .whole
			systemFlavor = .codeEditWhole
		case .proEdit:
			targetFormat = .architect
			systemFlavor = .architectPlan
		}
		
		promptManager.applySystemPromptOverride(systemFlavor, for: context)
		promptManager.applyXMLFormatOverride(targetFormat, for: context)
		
		syncSegmentSelections()
		
		// Delay resetting flag to allow SwiftUI's onChange handlers to complete
		Task { @MainActor in
			isApplyingSelection = false
		}
	}
	
private func syncSegmentSelections() {
		let config = resolvedPresetConfiguration()
		let systemOption = SystemPromptOption.option(for: config?.systemPromptFlavor)
		if systemPromptSelection != systemOption {
			systemPromptSelection = systemOption
		}
		
		let resolvedFormat = config?.xmlFormat
		let editOption = EditPromptOption.option(for: resolvedFormat)
		if editPromptSelection != editOption {
			editPromptSelection = editOption
		}
	}
	
	private func resolvedPresetConfiguration() -> PromptContextResolved? {
		switch context {
		case .copy:
			return promptManager.resolvePromptContext()
		case .chat:
			return promptManager.resolvedPromptContext(from: promptManager.currentChatPreset())
		}
	}
	
	private enum SystemPromptOption: CaseIterable, Identifiable {
		case none
		case agent
		case pair
		case discover
		
		var id: Self { self }
		
		var label: String {
			switch self {
			case .none: return "None"
			case .agent: return "MCP Agent"
			case .pair: return "MCP Pair Program"
			case .discover: return "MCP Discover"
			}
		}
		
		static var availableOptions: [SystemPromptOption] { Self.allCases }
		
		var systemPromptFlavor: SystemPromptFlavor? {
			switch self {
			case .none: return nil
			case .agent: return .mcpAgent
			case .pair: return .mcpPairProgram
			case .discover: return .mcpDiscover
			}
		}
		
		static func option(for flavor: SystemPromptFlavor?) -> SystemPromptOption {
			switch flavor {
			case .mcpAgent?: return .agent
			case .mcpPairProgram?: return .pair
			case .mcpDiscover?: return .discover
			default: return .none
			}
		}
	}
	
	private enum EditPromptOption: CaseIterable, Identifiable {
		case none
		case edit
		case editWhole
		case proEdit
		
		var id: Self { self }
		
		var label: String {
			switch self {
			case .none: return "None"
			case .edit: return "Edit (Diff)"
			case .editWhole: return "Edit (Whole)"
			case .proEdit: return "Pro Edit"
			}
		}
		
		static var availableOptions: [EditPromptOption] { Self.allCases }
		
		static func option(for format: ApplyPromptFormat?) -> EditPromptOption {
			switch format {
			case .architect?:
				return .proEdit
			case .diff?:
				return .edit
			case .whole?:
				return .editWhole
			case .none:
				return .none
			}
		}
	}
}

struct PromptDropDelegate: DropDelegate {
	let currentPrompt: PromptViewModel.StoredPrompt
	@Binding var prompts: [PromptViewModel.StoredPrompt]
	@Binding var draggedPrompt: PromptViewModel.StoredPrompt?
	let promptManager: PromptViewModel
	@Binding var dragTargetIndex: Int?
	let currentIndex: Int
	let context: PromptViewModel.PromptSelectionContext
	
	func dropEntered(info: DropInfo) {
		guard let draggedPrompt = draggedPrompt,
				draggedPrompt.id != currentPrompt.id else { return }
		
		withAnimation(.easeInOut(duration: 0.15)) {
			dragTargetIndex = currentIndex
		}
	}
	
	func dropExited(info: DropInfo) {
		withAnimation(.easeInOut(duration: 0.15)) {
			if dragTargetIndex == currentIndex {
				dragTargetIndex = nil
			}
		}
	}
	
	func performDrop(info: DropInfo) -> Bool {
		withAnimation(.easeInOut(duration: 0.3)) {
			dragTargetIndex = nil
		}
		
		promptManager.ensureManualPresetFor(context: context)
		
		guard let draggedPrompt = draggedPrompt,
				draggedPrompt.id != currentPrompt.id,
				let fromIndex = prompts.firstIndex(where: { $0.id == draggedPrompt.id }),
				let toIndex = prompts.firstIndex(where: { $0.id == currentPrompt.id }) else {
			return false
		}
		
		withAnimation(.easeInOut(duration: 0.3)) {
			let item = prompts.remove(at: fromIndex)
			prompts.insert(item, at: toIndex)
		}
		
		self.draggedPrompt = nil
		promptManager.saveStoredPrompts()
		return true
	}

}

struct StoredPromptRow: View {
	let prompt: PromptViewModel.StoredPrompt
	let isSelected: Bool
	let onToggle: () -> Void
	let onEdit: () -> Void
	let onDelete: (() -> Void)?
	let allowDelete: Bool
	@State private var isRowHovering = false
	@State private var isCopying = false
	@State private var hoveringButton: String?
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	init(
		prompt: PromptViewModel.StoredPrompt,
		isSelected: Bool,
		onToggle: @escaping () -> Void,
		onEdit: @escaping () -> Void,
		onDelete: (() -> Void)? = nil,
		allowDelete: Bool = true
	) {
		self.prompt = prompt
		self.isSelected = isSelected
		self.onToggle = onToggle
		self.onEdit = onEdit
		self.onDelete = onDelete
		self.allowDelete = allowDelete
	}
	
	var body: some View {
		HStack {
			Button(action: onToggle) {
				Image(systemName: isSelected ? (isRowHovering ? "minus.circle.fill" : "checkmark.circle.fill") : "plus.circle")
					.foregroundColor(isSelected ? .blue : .primary)
					.frame(width: 20, height: 20) // Reserve consistent space
			}
			.buttonStyle(PlainButtonStyle())
			
			Text(prompt.title)
				.font(fontPreset.font)
				.foregroundColor(.primary)
			
			Spacer()
			
			HStack(spacing: 8) {
				Button(action: {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(prompt.content, forType: .string)
					isCopying = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
						isCopying = false
					}
				}) {
					Image(systemName: isCopying ? "checkmark" : "doc.on.doc")
						.foregroundColor(hoveringButton == "copy" ? .blue : .primary)
						.frame(width: 20, height: 20)
				}
				.buttonStyle(PlainButtonStyle())
				.contentShape(Rectangle())
				.onHover { hovering in
					hoveringButton = hovering ? "copy" : nil
				}
				
				Button(action: onEdit) {
					Image(systemName: "pencil")
						.foregroundColor(hoveringButton == "edit" ? .blue : .primary)
						.frame(width: 20, height: 20)
				}
				.buttonStyle(PlainButtonStyle())
				.contentShape(Rectangle())
				.onHover { hovering in
					hoveringButton = hovering ? "edit" : nil
				}
				
				if allowDelete, let onDelete {
					Button(action: onDelete) {
						Image(systemName: "trash")
							.foregroundColor(hoveringButton == "delete" ? .red : .secondary)
							.frame(width: 20, height: 20)
					}
					.buttonStyle(PlainButtonStyle())
					.contentShape(Rectangle())
					.onHover { hovering in
						hoveringButton = hovering ? "delete" : nil
					}
				}
			}
			.opacity(isRowHovering ? 1 : 0)
		}
		.padding(.vertical, 5)
		.padding(.horizontal, 8)
		.background(isRowHovering ? Color.secondary.opacity(0.1) : Color.clear)
		.cornerRadius(8)
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isRowHovering = hovering
			}
		}
		.contentShape(Rectangle())
		.onTapGesture {
			onToggle()
		}
	}
}

struct PromptTag: View {
	let prompt: PromptViewModel.StoredPrompt
	let onRemove: () -> Void
	let onEdit: () -> Void
	@State private var isHovering = false
	@State private var showPopover = false
	@State private var isPreviewHovering = false
	@State private var isEditHovering = false
	@State private var isRemoveHovering = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		HStack(spacing: 4) {
			Button(action: {
				showPopover = true
			}) {
				Text(prompt.title)
					.font(fontPreset.font)
					.lineLimit(1)
					.foregroundColor(.primary)
			}
			.buttonStyle(PlainButtonStyle())
			
			if isHovering {
				HStack(spacing: 0) {
					Button(action: {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(prompt.content, forType: .string)
					}) {
						Image(systemName: "doc.on.doc")
							.foregroundColor(.primary)
							.frame(width: 28, height: 28)
							.contentShape(Rectangle())
					}
					.buttonStyle(PlainButtonStyle())
					.background(isPreviewHovering ? Color.secondary.opacity(0.3) : Color.clear)
					.cornerRadius(4)
					.onHover { hovering in
						isPreviewHovering = hovering
					}
					
					Divider()
						.frame(height: 16)
					
					Button(action: onEdit) {
						Image(systemName: "pencil")
							.foregroundColor(.primary)
							.frame(width: 28, height: 28)
							.contentShape(Rectangle())
					}
					.buttonStyle(PlainButtonStyle())
					.background(isEditHovering ? Color.secondary.opacity(0.3) : Color.clear)
					.cornerRadius(4)
					.onHover { hovering in
						isEditHovering = hovering
						if hovering {
							showPopover = false
						}
					}
					
					Divider()
						.frame(height: 16)
					
					Button(action: onRemove) {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.secondary)
							.font(.system(size: 12))
							.frame(width: 28, height: 28)
							.contentShape(Rectangle())
					}
					.buttonStyle(PlainButtonStyle())
					.background(isRemoveHovering ? Color.secondary.opacity(0.3) : Color.clear)
					.cornerRadius(4)
					.onHover { hovering in
						isRemoveHovering = hovering
						if hovering {
							showPopover = false
						}
					}
				}
				.background(Color.secondary.opacity(0.2))
				.cornerRadius(4)
				.transition(.opacity)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(Color.blue.opacity(0.1))
		.cornerRadius(8)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(Color.blue.opacity(0.3), lineWidth: 1)
		)
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHovering = hovering
			}
		}
		.popover(isPresented: $showPopover, arrowEdge: .leading) {
			PromptPreviewPopover(prompt: prompt)
		}
	}
}

struct PromptPreviewPopover: View {
	let prompt: PromptViewModel.StoredPrompt
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				Text(prompt.title)
					.font(fontPreset.headlineFont)
				
				Text(prompt.content)
					.font(fontPreset.font)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding()
		}
		.frame(width: 300, height: 200)
	}
}

struct PromptAuthorOverlay: View {
	@Binding var isVisible: Bool
	@Binding var editingPrompt: PromptViewModel.StoredPrompt?
	@ObservedObject var promptManager: PromptViewModel
	let context: PromptViewModel.PromptSelectionContext
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	@State private var title: String = ""
	@State private var content: String = ""
	@State private var externalUpdateTick: Int = 0

	var body: some View {
		VStack(spacing: 16) {
			Text("Stored Prompt").font(fontPreset.titleFont)

			TextField("Prompt Title", text: $title)
				.font(fontPreset.font)
				.textFieldStyle(RoundedBorderTextFieldStyle())

			TextKitView(text: $content, externalUpdateTick: externalUpdateTick)
				.frame(height: 300)
				.cornerRadius(5)
				.overlay(
					RoundedRectangle(cornerRadius: 5)
						.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
				)
				.overlay(
					Text(" Enter prompt to store here...")
						.font(fontPreset.font)
						.foregroundColor(.secondary)
						.opacity(content.isEmpty ? 1 : 0)
						.allowsHitTesting(false)
						.padding(10),
					alignment: .topLeading
				)
			
			HStack {
				Button(action: { isVisible = false }) {
					Text("Cancel")
				}
				.buttonStyle(CustomButtonStyle())
				
				Button(action: {
					if let editingPrompt = editingPrompt {
						promptManager.updateStoredPrompt(PromptViewModel.StoredPrompt(id: editingPrompt.id, title: title, content: content))
					} else {
						let newPrompt = promptManager.addStoredPrompt(title: title, content: content)
						promptManager.selectNewPrompt(newPrompt, context: context)
					}
					isVisible = false
				}) {
					Text("Save")
				}
				.buttonStyle(CustomButtonStyle())
			}
		}
		.padding()
		.frame(width: 480)
		.background(Color(NSColor.controlBackgroundColor))
		.cornerRadius(10)
		.shadow(radius: 10)
		.onAppear {
			if let editingPrompt = editingPrompt {
				title = editingPrompt.title
				content = editingPrompt.content
			} else {
				title = ""
				content = ""
			}
			// Force layout refresh after programmatic content change
			externalUpdateTick &+= 1
		}
	}
}

struct PrefPromptTag: View {
	let title: String
	let verboseTitle: String
	let color: Color
	let content: String
	@Binding var isOn: Bool
	@State private var isHovering = false
	@State private var showPopover = false
	@State private var isPreviewHovering = false
	@State private var isCopyHovering = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
    
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(fontPreset.font)
                .lineLimit(1)
                .foregroundColor(.primary)
            
            if isHovering {
                HStack(spacing: 0) {
					// No magnifying glass button here since clicking the tag shows the preview
                    
                    Divider()
                        .frame(height: 16)
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.primary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(isCopyHovering ? Color.secondary.opacity(0.3) : Color.clear)
                    .cornerRadius(4)
                    .onHover { hovering in
                        isCopyHovering = hovering
                        if hovering {
                            showPopover = false
                        }
                    }
                    
                    Divider()
                        .frame(height: 16)
                    
					Toggle("", isOn: $isOn)
						.toggleStyle(.checkbox)
						.frame(width: 28, height: 28)
						.contentShape(Rectangle())
						.offset(y: -2)
					
                }
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
                .transition(.opacity)
            }
        }
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(isOn ? color.opacity(0.1) : Color.gray.opacity(0.1))
		.cornerRadius(8)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(isOn ? color.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
		)
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHovering = hovering
			}
		}
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            PrefPromptPreviewPopover(title: verboseTitle, content: content)
        }
        .onTapGesture {
			showPopover = true
			// Don't toggle isOn here as we're using the tag tap for preview instead
        }
	}
}

/// A specialized tag to control whether we include the XML clipboard, and to pick
/// whether it’s “Diff” or “Whole.” Similar to PrefPromptTag, but uses a gear icon
/// to open a popover with the segmented picker.
struct XMLClipboardFormatTag: View {
	let title: String
	let color: Color
	
	/// Whether or not we're including this XML content in the clipboard
	@Binding var isOn: Bool
	
	/// Which format (Diff or Whole) is currently selected
	@Binding var selectedFormat: DiffViewModel.PromptFormat
	
	@State private var isHovering = false
	@State private var showPopover = false
	@State private var isGearHovering = false
	@State private var isCheckboxHovering = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		HStack(spacing: 4) {
			Text(title + " \(selectedFormat == .diff ? "Diff" : "Whole")")
				.font(fontPreset.font)
				.lineLimit(1)
				.foregroundColor(.primary)
			
			// Show the “gear + checkbox” row on hover
			if isHovering {
				HStack(spacing: 0) {
					// Gear icon to open the popover
					Button(action: {
						showPopover = true
					}) {
						Image(systemName: "gear")
							.foregroundColor(.primary)
							.frame(width: 28, height: 28)
							.contentShape(Rectangle())
					}
					.buttonStyle(PlainButtonStyle())
					.background(isGearHovering ? Color.secondary.opacity(0.3) : Color.clear)
					.cornerRadius(4)
					.onHover { hovering in
						isGearHovering = hovering
					}
					
					Divider()
						.frame(height: 16)
					
					// Toggle checkbox
					Toggle("", isOn: $isOn)
						.toggleStyle(.checkbox)
						.frame(width: 28, height: 28)
						.contentShape(Rectangle())
					// offset the checkbox a bit to align better visually
						.offset(y: -2)
						.onHover { hovering in
							isCheckboxHovering = hovering
						}
				}
				.background(Color.secondary.opacity(0.2))
				.cornerRadius(4)
				.transition(.opacity)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(isOn ? color.opacity(0.1) : Color.gray.opacity(0.1))
		.cornerRadius(8)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(isOn ? color.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
		)
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHovering = hovering
			}
		}
		// Popover with the “Format Settings” content (same as in DiffView)
		.popover(
			isPresented: $showPopover,
			attachmentAnchor: .rect(.bounds),
			arrowEdge: .leading
		){
			VStack(alignment: .leading, spacing: 8) {
				Text("Format Settings")
					.font(fontPreset.headlineFont)
				
				Picker("Format", selection: $selectedFormat) {
					ForEach(DiffViewModel.PromptFormat.allCases, id: \.self) { format in
						Text(format.rawValue)
							.font(fontPreset.font)
							.tag(format)
					}
				}
				.pickerStyle(SegmentedPickerStyle())
				
				Text("Diff: Outputs only the specific changes needed. Requires a powerful model (e.g. Sonnet 3.5).")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				
				Text("Whole: Outputs entire file contents with changes.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding()
			.frame(width: 300)
		}
		// If you want tapping the tag to toggle the checkbox, remove this if not desired
		.onTapGesture {
			isOn.toggle()
		}
	}
}
struct PrefPromptPreviewPopover: View {
	let title: String
	let content: String
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				Text(title)
					.font(fontPreset.headlineFont)
				
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(content.split(separator: "\n"), id: \.self) { line in
						Text(String(line))
							.font(.system(size: fontPreset.rawValue, design: .monospaced))
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding()
		}
		.frame(width: 400, height: 200)
	}
}
