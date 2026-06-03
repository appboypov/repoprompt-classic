import SwiftUI

/// A unified, preset-driven bottom bar for PromptView with:
/// - Two-pane preset pickers (copy/chat): icon + name + checkmark; hover preview on the left
/// - Prominent centered token readout
/// - Customize button (hidden for Manual) with badge when customized
/// - Right-aligned action buttons matching DualActionButton's style
///
/// Keyboard shortcuts preserved:
///  - Copy Now: ⌘ + ⇧ + C
///  - Send to Chat: ⌘ + ⇧ + N
struct PresetBottomBar: View {
    // View models
    @ObservedObject var promptVM: PromptViewModel
    @ObservedObject var fileManager: RepoFileManagerViewModel
    @ObservedObject var gitViewModel: GitViewModel

    // External actions
    var onCopyNow: () -> Void
    var onSendToChat: () -> Void

    // Show/hide the customization panel
    @Binding var showCustomization: Bool

    // Styling / environment
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }

    // Hover states for styled controls
    @State private var hoverCustomize = false
    @State private var hoverCopyButton = false
    @State private var hoverChatButton = false

    // Popover controls
    @State private var showCopyPicker = false
    @State private var showChatPicker = false

	private var barRowHeight: CGFloat { fontPreset.scaledClamped(40, min: 40, max: 50) }
	private var barVerticalPadding: CGFloat { fontPreset.scaledClamped(6, min: 6, max: 9) }
	private var pillHeight: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 36) }
	private var pillHorizontalPadding: CGFloat { fontPreset.scaledClamped(10, min: 10, max: 14) }
	private var copyButtonWidth: CGFloat { fontPreset.scaledClamped(120, min: 120, max: 154) }
	private var chatButtonWidth: CGFloat { fontPreset.scaledClamped(130, min: 130, max: 166) }
	
    // MARK: - Body
    var body: some View {
        ZStack {
            // Left & right rails
            HStack(spacing: 8) {
                // LEFT: Preset pickers + customize
                HStack(spacing: 8) {
                    copyPresetPicker
                    chatPresetPicker
                    customizeButtonIfNeeded
                }

                Spacer(minLength: 8)

                // RIGHT: action buttons
                HStack(spacing: 8) {
                    copyNowButton
                    sendToChatButton
                }
            }
			.frame(height: barRowHeight)
			.padding(.horizontal, pillHorizontalPadding)
			.padding(.vertical, barVerticalPadding)

            // CENTER: prominent token readout – always centered
            tokenReadout
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.systemGray).opacity(0.4), lineWidth: 0.5)
        )
		
    }

    // MARK: - Copy Preset Picker (two‑pane popover)
    private var copyPresetPicker: some View {
        let presetsRaw = CopyPresetManager.shared.allPresets.filter { CopyPresetManager.shared.isPresetVisible($0) }
		let allCopyPresets: [CopyPreset] = presetsRaw.isEmpty ? [BuiltInCopyPresets.standard] : presetsRaw
		let selectedIdRaw = promptVM.selectedCopyPresetID ?? BuiltInCopyPresets.standard.id
        let current = promptVM.currentCopyPreset()
		// Ensure the selection we pass into the popover exists in the displayed list
		let effectiveSelectedId = allCopyPresets.first(where: { $0.id == selectedIdRaw })?.id
			?? allCopyPresets.first?.id
			?? current.id

        return Button {
            showCopyPicker.toggle()
        } label: {
            PresetPickerLabel(
                prefix: "Copy",
                name: current.name,
                fallbackSystemSymbol: "doc.on.clipboard",
                emoji: current.icon,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCopyPicker, arrowEdge: .bottom) {
            PresetTwoPanePopover_Copy(
                allPresets: allCopyPresets,
				selectedId: effectiveSelectedId,
                fontPreset: fontPreset,
                windowID: promptVM.windowID,
                previewBuilder: { preset in
                    CopyPresetPreviewView(preset: preset, fontPreset: fontPreset, promptViewModel: promptVM)
                },
                onSelect: { preset in
                    // Toggle customization when switching to/from Manual
                    let wasManual = promptVM.currentCopyPreset().builtInKind == .manual
                    promptVM.selectCopyPreset(preset.id)
                    let isManualNow = preset.builtInKind == .manual
                    if wasManual && !isManualNow {
                        showCustomization = false
                    } else if !wasManual && isManualNow {
                        showCustomization = true
                    }
                    showCopyPicker = false
                }
            )
			.frame(width: 520 * fontPreset.scaleFactor, height: 344 * fontPreset.scaleFactor)
            .padding(10)
        }
        .help(copyPresetHelpText(current))
        .accessibilityLabel("Copy preset menu")
    }

    // MARK: - Chat Preset Picker (two‑pane popover)
    private var chatPresetPicker: some View {
        let presetsRaw = ChatPresetManager.shared.allPresets.filter { ChatPresetManager.shared.isPresetVisible($0) }
        let allChatPresets: [ChatPreset] = presetsRaw.isEmpty ? ChatPreset.BuiltIn.all : presetsRaw
		let selectedIdRaw = promptVM.selectedChatPresetID ?? ChatPreset.BuiltIn.chat.id
		let current = allChatPresets.first(where: { $0.id == selectedIdRaw }) ?? (allChatPresets.first ?? ChatPreset.BuiltIn.chat)
		// Ensure the selection we pass into the popover exists in the displayed list
		let effectiveSelectedId = allChatPresets.first(where: { $0.id == selectedIdRaw })?.id
			?? current.id

        return Button {
            showChatPicker.toggle()
        } label: {
            PresetPickerLabel(
                prefix: "Chat",
                name: current.name,
                fallbackSystemSymbol: "bubble.left.and.bubble.right",
                emoji: current.icon,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showChatPicker, arrowEdge: .bottom) {
            PresetTwoPanePopover_Chat(
                allPresets: allChatPresets,
				selectedId: effectiveSelectedId,
                fontPreset: fontPreset,
                windowID: promptVM.windowID,
                promptViewModel: promptVM,
                previewBuilder: { preset in
					ChatPresetPreviewView(preset: preset, fontPreset: fontPreset, promptViewModel: promptVM)
                },
                onSelect: { preset in
                    promptVM.selectChatPreset(preset.id)
                    showChatPicker = false
                }
            )
			.frame(width: 520 * fontPreset.scaleFactor, height: 344 * fontPreset.scaleFactor)
            .padding(10)
        }
        .help(chatPresetHelpText(current))
        .accessibilityLabel("Chat preset menu")
    }

    // MARK: - Customize Button (hidden for Manual)
    private var customizeButtonIfNeeded: some View {
        let isManual = (promptVM.currentCopyPreset().builtInKind == .manual)
        return Group {
            if !isManual {
                Button(action: {
                    withAnimation(.easeInOut) {
                        showCustomization.toggle()
                    }
                }) {
                    StyledCapsuleLabel(
                        isHovering: hoverCustomize,
                        label: {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(fontPreset.captionFont.weight(.medium))
                                Text(showCustomization ? "Hide options" : "Customize")
                                    .font(fontPreset.standardFont)
                            }
							.padding(.horizontal, pillHorizontalPadding)
							.frame(height: pillHeight)
                            .overlay(alignment: .topTrailing) {
                                if isCustomized {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
                .onHover { hoverCustomize = $0 }
                .accessibilityLabel("Customize preset options")
                .help("Toggle inline customization panel")
            }
        }
    }

    // MARK: - Token Readout (centered)
    private var tokenReadout: some View {
        let total = promptVM.totalTokenCount
        let color = tokenColor(total: total)
        let approx = promptVM.tokenCountingViewModel.tokenCount // e.g. "12.5k"
        return HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(fontPreset.captionFont)
            Text("~\(approx) tokens")
                .font(fontPreset.headlineFont) // make it prominent
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(color)
        .help(tokenWarningHelp)
        .accessibilityLabel("Approximate token total \(approx)")
    }

    private func tokenColor(total: Int) -> Color {
        if total > 100_000 { return .red }
        if total >= 60_000 { return .orange }
        return .green
    }

    // MARK: - Action Buttons (right)
    private var copyNowButton: some View {
        Button(action: onCopyNow) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                Text("Copy Prompt")
            }
            .font(fontPreset.standardFont)
			.frame(width: copyButtonWidth, height: pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(isHovering: hoverCopyButton))
        .onHover { hoverCopyButton = $0 }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .accessibilityLabel("Copy Prompt")
        .help(resolvedCopySummary())
    }

    private var sendToChatButton: some View {
        Button(action: onSendToChat) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("Send to Chat")
            }
            .font(fontPreset.standardFont)
			.frame(width: chatButtonWidth, height: pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle(isHovering: hoverChatButton))
        .onHover { hoverChatButton = $0 }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .accessibilityLabel("Send to Chat")
        .help(resolvedChatSummary())
    }

    // MARK: - Helpers (customization badge + tooltips)
    private var isCustomized: Bool {
        let preset = promptVM.currentCopyPreset()
        var changed = false

        if let ft = preset.fileTreeMode, ft != promptVM.fileTreeOption {
            changed = true
        }
        if let cm = preset.codeMapUsage, cm != promptVM.codeMapUsage {
            changed = true
        }
        if let gi = preset.gitInclusion {
            let expected: GitDiffInclusionMode = (gi == .none) ? .none : .selectedFiles
            if gitViewModel.gitDiffInclusionMode != expected {
                changed = true
            }
        }
        return changed
    }

    private var tokenWarningHelp: String {
        let baseMessage = promptVM.totalTokenCount >= 50_000
            ? "Token count is getting high, which may affect performance."
            : "Current estimated token count"
        let breakdown = promptVM.tokenBreakdownDescription
        if !breakdown.isEmpty {
            return "\(baseMessage)\n\(breakdown)"
        }
        return baseMessage
    }

    private func resolvedCopySummary() -> String {
        let cfg = promptVM.resolvePromptContext(promptVM.currentCopyPreset(), custom: promptVM.workingCopyCustomizations)
        return summaryString(cfg)
    }

    private func resolvedChatSummary() -> String {
        let chat = promptVM.currentChatPreset()
        return "[Chat: \(chat.name)]\nMode: \(chat.mode.displayName)"
    }

    private func summaryString(_ cfg: PromptContextResolved) -> String {
        let xml = cfg.xmlFormat?.rawValue ?? "none"
        return """
        Includes: files=\(cfg.includeFiles ? "yes" : "no"), user=\(cfg.includeUserPrompt ? "yes" : "no"), meta=\(cfg.includeMetaPrompts ? "yes" : "no")
        File Tree: \(cfg.fileTreeMode.rawValue)
        Code Map: \(cfg.codeMapUsage.rawValue)
        Git: \(cfg.gitInclusion.rawValue)
        XML: \(xml)\(cfg.systemPromptFlavor.map { "\nSystem: \($0)" } ?? "")
        """
    }

    private func copyPresetHelpText(_ preset: CopyPreset) -> String {
        var parts: [String] = []
        parts.append("Copy Preset")
        parts.append(preset.name)
        if let desc = preset.description, !desc.isEmpty {
            parts.append(desc)
        }
        if preset.builtInKind == .manual {
            parts.append("Manual mode gives full control with all settings visible.")
        }
        return parts.joined(separator: "\n")
    }

    private func chatPresetHelpText(_ preset: ChatPreset) -> String {
        var parts: [String] = []
        parts.append("Chat Preset")
        parts.append(preset.name)
        if let desc = preset.description, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Shared Label for the picker buttons
struct PresetPickerLabel: View {
    let prefix: String
    let name: String
    let fallbackSystemSymbol: String
    let emoji: String?
    let fontPreset: FontScalePreset

    @State private var isHovering = false

    var body: some View {
        StyledCapsuleLabel(
            isHovering: isHovering,
            label: {
                HStack(spacing: 6) {
                    if let emoji, !emoji.isEmpty {
                        Text(emoji)
                    } else {
                        Image(systemName: fallbackSystemSymbol)
                            .font(fontPreset.captionFont)
                    }
                    Text("\(prefix): \(name)")
                        .font(fontPreset.standardFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
				.padding(.horizontal, fontPreset.scaledClamped(10, min: 10, max: 14))
				.frame(height: fontPreset.scaledClamped(28, min: 28, max: 36))
            }
        )
        .onHover { isHovering = $0 }
    }
}

// MARK: - Two‑pane popovers

/// COPY preset two‑pane popover
struct PresetTwoPanePopover_Copy<Left: View>: View {
    let allPresets: [CopyPreset]
    let selectedId: UUID
    let fontPreset: FontScalePreset
    let windowID: Int
    let previewBuilder: (CopyPreset) -> Left
    let onSelect: (CopyPreset) -> Void

    @State private var hoveredId: UUID?
    
    // Separate standard, XML, MCP, and custom presets
    private var standardPresets: [CopyPreset] {
        allPresets.filter { preset in
            preset.isBuiltIn &&
            !preset.name.hasPrefix("MCP") &&
            !preset.name.contains("XML") &&
            preset.name != "XML Pro Edit"
		}.sorted { first, second in
			// Put Manual at the bottom
			if first.name == "Manual" { return false }
			if second.name == "Manual" { return true }
			// Keep original order for others
			return allPresets.firstIndex(where: { $0.id == first.id })! <
					allPresets.firstIndex(where: { $0.id == second.id })!
        }
    }
    
    private var xmlPresets: [CopyPreset] {
        allPresets.filter { preset in
            preset.isBuiltIn &&
            (preset.name.contains("XML") || preset.name == "XML Pro Edit")
        }
    }
    
    private var mcpPresets: [CopyPreset] {
        allPresets.filter { preset in
            preset.isBuiltIn &&
            preset.name.hasPrefix("MCP")
        }
    }
    
    private var customPresets: [CopyPreset] {
        allPresets.filter { preset in
            !preset.isBuiltIn
        }
    }

    var body: some View {
        HStack(spacing: 10 * fontPreset.scaleFactor) {
            // LEFT: preview pane
            VStack(alignment: .leading, spacing: 6 * fontPreset.scaleFactor) {
                if let p = allPresets.first(where: { $0.id == (hoveredId ?? selectedId) }) {
                    previewBuilder(p)
                }
                Spacer()
            }
            .frame(width: 320 * fontPreset.scaleFactor, alignment: .topLeading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .cornerRadius(8)

            // RIGHT: list with sections
			ZStack(alignment: .topTrailing) {
				ScrollView {
					VStack(alignment: .leading, spacing: 6) {
						Spacer().frame(height: 4)
                    // Standard Copy Modes
                    if !standardPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Standard Modes")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                            
                            ForEach(standardPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "bubble.left.and.bubble.right",
                                    title: preset.name,
                                    subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
                                    onSelect(preset)
                                }
                            }
                        }
                    }
                    
                    // XML Edit Modes
                    if !xmlPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("XML Edit Modes")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 2)
                                .padding(.bottom, 2)
                            
                            ForEach(xmlPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "doc.text",
                                    title: preset.name,
                                    subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
                                    onSelect(preset)
                                }
                            }
                        }
                    }
                    
                    // MCP-Powered Modes
                    if !mcpPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MCP-Powered Modes")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 2)
                                .padding(.bottom, 2)
                            
                            ForEach(mcpPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "cpu",
                                    title: preset.name,
									subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
									if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
									onSelect(preset)
                                }
                            }
                        }
                    }
                    
                    // Custom Presets
                    if !customPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Presets")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 2)
                                .padding(.bottom, 2)
                            
                            ForEach(customPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "square.dashed",
                                    title: preset.name,
                                    subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
                                    onSelect(preset)
                                }
                            }
                        }
                    }
                }
            }
				
				// Gear button overlay
				Button(action: {
					NotificationCenter.default.post(
						name: .showCopyPresetsTab,
						object: nil,
						userInfo: ["windowID": windowID]
					)
					// Safely re-select the current (or first available) preset to close the popover
					if let current = allPresets.first(where: { $0.id == selectedId }) {
						onSelect(current)
					} else if let fallback = allPresets.first {
						onSelect(fallback)
					} // else: no presets; do nothing (popover stays open but no crash)
				}) {
					Image(systemName: "gearshape")
						.font(fontPreset.standardFont)
						.foregroundColor(.primary)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Manage Chat Presets")
				.padding(.trailing, 4)
				.padding(.top, 0)
			}
        }
    }
}

/// CHAT preset two‑pane popover
struct PresetTwoPanePopover_Chat<Left: View>: View {
    let allPresets: [ChatPreset]
    let selectedId: UUID
    let fontPreset: FontScalePreset
    let windowID: Int
    let promptViewModel: PromptViewModel?  // Optional for compatibility
    let previewBuilder: (ChatPreset) -> Left
    let onSelect: (ChatPreset) -> Void
    
    @State private var hoveredId: UUID?
    @State private var showProEditSettings = false
    
    // Separate standard and MCP presets
    private var standardPresets: [ChatPreset] {
        allPresets.filter { preset in
            !preset.name.hasPrefix("MCP") && !preset.name.contains("XML")
		}.sorted { first, second in
			// Put Manual at the bottom
			if first.name == "Manual" { return false }
			if second.name == "Manual" { return true }
			// Keep original order for others
			return allPresets.firstIndex(where: { $0.id == first.id })! <
					allPresets.firstIndex(where: { $0.id == second.id })!
        }
    }
    
    private var xmlPresets: [ChatPreset] {
        allPresets.filter { preset in
            preset.name.contains("XML")
        }
    }
    
    private var mcpPresets: [ChatPreset] {
        allPresets.filter { preset in
            preset.name.hasPrefix("MCP")
        }
    }

    var body: some View {
        HStack(spacing: 10 * fontPreset.scaleFactor) {
            // LEFT: preview pane
            VStack(alignment: .leading, spacing: 6 * fontPreset.scaleFactor) {
                if let p = allPresets.first(where: { $0.id == (hoveredId ?? selectedId) }) {
                    previewBuilder(p)
                }
                Spacer()
            }
            .frame(width: 320 * fontPreset.scaleFactor, alignment: .topLeading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .cornerRadius(8)

            // RIGHT: list with sections
			ZStack(alignment: .topTrailing) {
				ScrollView {
					VStack(alignment: .leading, spacing: 6) {
					// Standard Copy Modes
						Spacer().frame(height: 4)
                    if !standardPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Standard Modes")
                                .font(fontPreset.captionFont.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                            
                            ForEach(standardPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "bubble.left.and.bubble.right",
                                    title: preset.name,
                                    subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
                                    onSelect(preset)
                                }
                            }
                        }
                    }
                    
                    // XML Edit Modes - moved before MCP for better logical grouping
                    if !xmlPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("XML Edit Modes")
                                .font(fontPreset.captionFont.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            
                            ForEach(xmlPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "doc.text",
                                    title: preset.name,
                                    subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
                                    onSelect(preset)
                                }
                            }
                        }
                    }
                    
                    // MCP-Powered Modes
                    if !mcpPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MCP-Powered Modes")
                                .font(fontPreset.captionFont.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            
                            ForEach(mcpPresets, id: \.id) { preset in
                                PresetOptionRow(
                                    leadingEmoji: preset.icon,
                                    fallbackSystemSymbol: "cpu",
                                    title: preset.name,
									subtitle: nil,
                                    isSelected: preset.id == selectedId
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .onHover { hovering in
									if hovering { hoveredId = preset.id }
                                }
                                .onTapGesture {
									onSelect(preset)
                                }
                            }
                        }
                    }
                }
            }
				
				// Gear button overlay
				Button(action: {
					NotificationCenter.default.post(
						name: .showChatPresetsTab,
						object: nil,
						userInfo: ["windowID": windowID]
					)
					// Safely re-select the current (or first available) preset to close the popover
					if let current = allPresets.first(where: { $0.id == selectedId }) {
						onSelect(current)
					} else if let fallback = allPresets.first {
						onSelect(fallback)
					} // else: no presets; do nothing (popover stays open but no crash)
				}) {
					Image(systemName: "gearshape")
						.font(fontPreset.standardFont)
						.foregroundColor(.primary)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Manage Copy Presets")
				.padding(.trailing, 4)
				.padding(.top, 0)
        }
        }
    }
}

private struct PresetOptionRow: View, Equatable {
    let leadingEmoji: String?
    let fallbackSystemSymbol: String
    let title: String
    let subtitle: String?
    let isSelected: Bool
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let leadingEmoji, !leadingEmoji.isEmpty {
                Text(leadingEmoji)
                    .font(.system(size: 14 * fontPreset.scaleFactor))
            } else {
                Image(systemName: fallbackSystemSymbol)
                    .font(.system(size: 12 * fontPreset.scaleFactor))
            }
            
			VStack(alignment: .leading, spacing: 1) {
				Text(title)
					.font(fontPreset.standardFont)
					.lineLimit(1)
					.truncationMode(.tail)
				if let subtitle {
					Text(subtitle)
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
			}
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11 * fontPreset.scaleFactor))
            }
        }
		.frame(height: fontPreset.scaledClamped(28, min: 28, max: 36))
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.75) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.systemGray).opacity(isHovering ? 0.6 : 0.3), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    static func == (lhs: PresetOptionRow, rhs: PresetOptionRow) -> Bool {
        lhs.leadingEmoji == rhs.leadingEmoji &&
        lhs.fallbackSystemSymbol == rhs.fallbackSystemSymbol &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.isSelected == rhs.isSelected
    }
}

// MARK: - Preview Views for Presets

struct CopyPresetPreviewView: View {
    let preset: CopyPreset
    let fontPreset: FontScalePreset
    let promptViewModel: PromptViewModel?
    
    @State private var showProEditSettings = false
    
    private var presetSubtitle: String {
        if preset.isBuiltIn {
            return CopyPresetManager.shared.hasOverrides(preset.id) ? "Built-in (modified)" : "Built-in preset"
        } else {
            return "Custom preset"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                if let icon = preset.icon, !icon.isEmpty {
                    Text(icon)
                        .font(.system(size: 24))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.primary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(fontPreset.headlineFont)
                        .foregroundColor(.primary)
                    Text(presetSubtitle)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Pro Edit config button
                if preset.builtInKind == .proEdit {
                    Button {
                        showProEditSettings.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                            Text("Pro Edit Config")
                                .font(fontPreset.standardFont)
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .popover(isPresented: $showProEditSettings) {
                        if let vm = promptViewModel {
                            ProEditSettingsView(promptViewModel: vm)
                                .frame(width: 475, height: 380)
                                .padding()
                        }
                    }
                }
            }
            
            // Context Overview grid
            VStack(alignment: .leading, spacing: 8) {
                Text("Context Overview")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    // Selected Files
                    ContextTile(
                        iconName: "doc.on.doc",
                        title: "Selected Files",
                        detail: selectedFilesDetail,
                        active: includeFiles,
                        isCompressed: preset.name.hasPrefix("MCP") && codeMapActive
                    )
                    
                    // File Tree
                    ContextTile(
                        iconName: fileTreeIconName,
                        title: "File Tree",
                        detail: fileTreeDetail,
                        active: includeFileTree
                    )
                    
                    // Code Map
                    ContextTile(
                        iconName: codeMapIconName,
                        title: "Code Map",
                        detail: codeMapDetail,
                        active: codeMapActive
                    )
                    
                    // Git Diff
                    ContextTile(
                        iconName: gitIconName,
                        title: "Git Diff",
                        detail: gitDetail,
                        active: gitActive
                    )
                    
                    // User Prompt
                    ContextTile(
                        iconName: "rectangle.and.pencil.and.ellipsis",
                        title: "User Prompt",
                        detail: includeUserPrompt ? "Included" : "Excluded",
                        active: includeUserPrompt
                    )
                    
                    // Meta Prompts
                    ContextTile(
                        iconName: "text.bubble",
                        title: "Meta Prompts",
                        detail: metaPromptsDetail,
                        active: includeMetaPromptsEffective
                    )
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.systemGray).opacity(0.25), lineWidth: 0.5)
            )
            
            Divider()
            
            // When to use
            VStack(alignment: .leading, spacing: 6) {
                Text("When to use")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                Text(whenToUseDescription)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // About this mode
            VStack(alignment: .leading, spacing: 6) {
                Text("About this mode")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                Text(bestForDescription)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - Grid Layout
    private var gridColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 10, alignment: .topLeading)
        ]
    }
    
    // MARK: - Resolved config and computed state
    private var cfg: PromptContextResolved? {
        guard let vm = promptViewModel else { return nil }
        return vm.resolvePromptContext(preset, custom: vm.workingCopyCustomizations)
    }
    
    private var includeFiles: Bool {
        cfg?.includeFiles ?? true
    }
    private var includeUserPrompt: Bool {
        cfg?.includeUserPrompt ?? true
    }
    private var includeMetaPromptsFlag: Bool {
        // Raw include flag from config; may not reflect actual content presence
        cfg?.includeMetaPrompts ?? false
    }
    private var includeFileTree: Bool {
        (cfg?.includeFileTree ?? false) && ((cfg?.fileTreeMode ?? .none) != .none)
    }
    private var codeMapActive: Bool {
        (cfg?.codeMapUsage ?? .none) != .none
    }
    private var gitActive: Bool {
        (cfg?.gitInclusion ?? .none) != .none
    }
    
    private var fileTreeMode: FileTreeOption {
        cfg?.fileTreeMode ?? .none
    }
    private var codeMapUsage: CodeMapUsage {
        cfg?.codeMapUsage ?? .none
    }
    private var gitMode: GitInclusion {
        cfg?.gitInclusion ?? .none
    }
    
    // Only the plain "Manual" preset (no system flavor) should reflect selected prompts.
    private var isPlainManual: Bool {
        (preset.builtInKind == .manual) && (cfg?.systemPromptFlavor == nil)
    }
    
    // Meta Prompts tile active:
    //  - true if a system flavor exists
    //  - OR if there are stored prompt IDs referenced
    //  - OR (plain Manual AND there are selected prompts)
    private var includeMetaPromptsEffective: Bool {
        if cfg?.systemPromptFlavor != nil { return true }
        if let ids = cfg?.storedPromptIds, !ids.isEmpty { return true }
        if isPlainManual, let vm = promptViewModel {
            return !vm.getSelectedPromptIDsSnapshot().isEmpty
        }
        return false
    }
    
    // MARK: - Stats (concise details)
    private var selectedFilesDetail: String {
        guard includeFiles, let vm = promptViewModel else { return "Excluded" }
        let count = vm.fileManager.selectedFiles.count
        
        // Check if this is an MCP preset with codemap compression
        let isMCPWithCompression = preset.name.hasPrefix("MCP") && codeMapActive
        if isMCPWithCompression {
            return "\(count) \(count == 1 ? "codemap" : "codemaps")"
        } else {
            return "\(count) \(count == 1 ? "file" : "files")"
        }
    }
    
    private var fileTreeDetail: String {
        guard includeFileTree else { return "Excluded" }
        return fileTreeMode.rawValue
    }
    
    private var codeMapDetail: String {
        guard codeMapActive else { return "Excluded" }
        return codeMapUsage.rawValue.capitalized
    }
    
    private var gitDetail: String {
        guard gitActive else { return "Excluded" }
        switch gitMode {
        case .none: return "Excluded"
        case .selected: return "Selected"
        case .complete: return "Complete"
        }
    }
    
    // Meta prompt detail:
    // - For presets with a system flavor: show friendly flavor name (no "System:" prefix)
    // - For presets with storedPromptIds: show the referenced prompts
    // - For plain Manual: show first selected meta prompt name (+N more), or "None selected" if empty
    // - For other presets without a system flavor: "None"
    private var metaPromptsDetail: String {
        if let flavor = cfg?.systemPromptFlavor {
            return friendlyFlavorName(flavor)
        }
        
        // Check for stored prompt IDs in the preset
        if let promptIds = cfg?.storedPromptIds, !promptIds.isEmpty, let vm = promptViewModel {
			let nameMap: [UUID: String] = Dictionary(vm.storedPrompts.map { ($0.id, $0.title) }, uniquingKeysWith: { _, latest in latest })
            let names = promptIds.compactMap { nameMap[$0] }
            guard let first = names.first else { return "None" }
            
            let firstTrunc = truncated(first, max: 28)
            if names.count > 1 {
                return "\(firstTrunc) +\(names.count - 1) more"
            } else {
                return firstTrunc
            }
        }
        
        guard isPlainManual, let vm = promptViewModel else { return "None" }
        let selected = vm.getSelectedPromptIDsSnapshot()
        guard !selected.isEmpty else { return "None selected" }
        
		let nameMap: [UUID: String] = Dictionary(vm.storedPrompts.map { ($0.id, $0.title) }, uniquingKeysWith: { _, latest in latest })
        let names = selected.compactMap { nameMap[$0] }
        guard let first = names.first else { return "None selected" }
        
        let firstTrunc = truncated(first, max: 28)
        if names.count > 1 {
            return "\(firstTrunc) +\(names.count - 1) more"
        } else {
            return firstTrunc
        }
    }
    
    // MARK: - Icon mappings (reused from pref tags)
    private var fileTreeIconName: String {
        switch fileTreeMode {
        case .auto:
            return "arrow.triangle.2.circlepath.circle"
        case .files:
            return "list.bullet.rectangle"
		case .selected:
            return "target"
        case .none:
            return "xmark.circle"
        }
    }
    
    private var codeMapIconName: String {
        switch codeMapUsage {
        case .auto:
            return "arrow.triangle.2.circlepath.circle"
        case .complete:
            return "checkmark.circle.fill"
        case .selected:
            return "target"
        case .none:
            return "xmark.circle"
        }
    }
    
    private var gitIconName: String {
        switch gitMode {
        case .none:
            return "circle"
        case .selected:
            return "smallcircle.filled.circle"
        case .complete:
            return "circle.fill"
        }
    }
    
    // MARK: - When to use description
    private var whenToUseDescription: String {
        if let flavor = cfg?.systemPromptFlavor {
            switch flavor {
            case .architectPlan:
                return "• Large multi-file changes\n• Need faster response times\n• Want higher edit accuracy"
            case .codeEditDiff:
                return "• Making targeted bug fixes\n• Want to preserve surrounding context\n• Need reviewable, minimal diffs"
            case .codeEditWhole:
                return "• Large-scale refactoring needed\n• Complete file rewrites required\n• Diffs would be too verbose"
            case .review:
                return "• Pre-merge code review\n• Identifying potential issues\n• Reviewing recent changes with full context"
            case .mcpAgent:
                return "• Prime Claude Code/Codex agents\n• Complex multi-step workflows\n• Efficient context with codemaps"
            case .mcpPairProgram:
                return "• Complex features needing accuracy\n• Want dual-model accountability\n• Long context retention needed"
            case .mcpPairPlan:
                return "• Discover codebase context\n• Setup file selection for next step\n• Generate report for planning"
            case .mcpDiscover:
                return "• Discover codebase context\n• Use codemaps to locate relevant modules\n• Generate a context report and refine the task"
            case .mcpBuilder:
                return "• Deep context via context_builder\n• Refine plan with chat as seer\n• Implement directly with MCP tools"
            }
        }

        switch preset.builtInKind {
        case .some(.standard):
            return "• General everyday coding tasks\n• Quick bug fixes and features\n• Standard development workflow"
        case .some(.plan):
            return "• Complex features requiring planning\n• Need step-by-step implementation guide\n• Multi-component changes"
        case .some(.manual):
            if preset.name.contains("XML") {
                return "• Add custom prompts to XML editing\n• Want XML format with meta prompts\n• Full control over context"
            }
            return "• Want full control over context\n• Need to tweak settings inline\n• Custom workflow requirements"
        case .some(.editXML):
            return "• Standard code editing tasks\n• Want reviewable XML diffs\n• Clear before/after visibility"
        case .some(.proEdit):
            return "• Large multi-file changes\n• Need faster response times\n• Want higher edit accuracy"
        case .some(.diffFollowUp):
            return "• Track progress against external plan\n• Verify changes align with strategy\n• Quick follow-up on recent commits"
        case .some(.codeReview):
            return "• Comprehensive code review\n• Pre-merge quality checks\n• Full context review with git history"
        case .some(.mcpAgent):
            return "• Prime Claude Code/Codex agents\n• Complex multi-step workflows\n• Efficient context with codemaps"
        case .some(.mcpPair):
            return "• Complex features needing accuracy\n• Want dual-model accountability\n• Long context retention needed"
        case .some(.mcpPlan):
            return "• Identify required context for task\n• Setup file selection for next step\n• Generate report for planning"
        case .some(.mcpBuilder):
            return "• Deep context via context_builder\n• Refine plan with chat as seer\n• Implement directly with MCP tools"
        case .none:
            if preset.name.lowercased().contains("review") {
                return "• Code review workflows\n• Pre-merge checks\n• Quality assessment"
            } else if preset.name.lowercased().contains("xml") {
                return "• XML-based editing\n• Structured changes\n• Clear diff format"
            }
            return "• Custom workflow needs\n• Flexible configuration\n• Adaptive context"
        }
    }
    
    // MARK: - Usage description
    private var bestForDescription: String {
        if let flavor = cfg?.systemPromptFlavor {
            switch flavor {
            case .architectPlan:
                return "Delegates file edits to API models - faster model output, higher accuracy, and better for complex multi-file changes."
            case .codeEditDiff:
                return "Makes precise, minimal code edits using XML diff format."
            case .codeEditWhole:
                return "Rewrites full files when large refactors are needed."
            case .review:
                return "Reviews code with full context and git changes to identify issues and improvements."
            case .mcpAgent:
                return "Primes agent context with codemaps and MCP tool instructions for efficient workflows."
            case .mcpPairProgram:
                return "Uses RepoPrompt chat for dual-model accountability and long context retention."
            case .mcpPairPlan:
                return "Discovers context and generates a report to setup file selection for next agent."
            case .mcpDiscover:
                return "Discovers context and generates a report to setup file selection for next agent."
            case .mcpBuilder:
                return "Builds deep context via context_builder, refines with chat, then implements directly using MCP tools."
            }
        }

        switch preset.builtInKind {
        case .some(.standard):
			return "Balanced configuration with files and file tree for everyday coding tasks."
        case .some(.plan):
            return "Creates step-by-step implementation plans before making code changes."
        case .some(.manual):
            if preset.name.contains("XML") {
                return "XML editing with your custom prompts and current manual settings."
            }
            return "Uses your current workspace state exactly as configured."
        case .some(.editXML):
			return "Model outputs XML blocks with all changes for reviewable diffs - works best with frontier models like GPT-5, Gemini 3.1 Pro, Sonnet/Opus 4.0."
        case .some(.proEdit):
            return "Delegates file edits to API models - faster model output, higher accuracy, and better for complex multi-file changes."
        case .some(.diffFollowUp):
            return "Git diff only to verify changes align with external plan and track implementation progress."
        case .some(.codeReview):
            return "Comprehensive code review with file tree, code maps, and git diff."
        case .some(.mcpAgent):
            return "Prime agents with compressed codebase context and guidance on using Repo Prompt tools."
        case .some(.mcpPair):
            return "Agent uses Repo Prompt chat for dual-model accountability and extended context retention."
        case .some(.mcpPlan):
            return "Discovers context and writes reports to setup file selection - follow with Plan or MCP Pair."
        case .some(.mcpBuilder):
            return "Builds deep context via context_builder, refines with chat, then implements directly using MCP tools."
        case .none:
            if preset.name.lowercased().contains("review") {
                return "Reviews changes and provides structured feedback for quality assurance."
            } else if preset.name.lowercased().contains("xml") {
                return "XML-based code edits for structured, reviewable changes."
            }
            return "Flexible preset that adapts to your current configuration."
        }
    }
    
    // MARK: - Helpers
    private func truncated(_ s: String, max: Int) -> String {
        if s.count > max {
            let prefix = s.prefix(max - 1)
            return String(prefix) + "…"
        }
        return s
    }
    
    private func friendlyFlavorName(_ flavor: SystemPromptFlavor) -> String {
        switch flavor {
        case .architectPlan:      return "Pro Edit (Architect)"
        case .codeEditDiff:       return "Code Edit (Diff)"
        case .codeEditWhole:      return "Code Edit (Whole)"
        case .review:             return "Code Review"
        case .mcpAgent:           return "MCP Agent"
        case .mcpPairProgram:     return "MCP Pair Program"
        case .mcpPairPlan:        return "MCP Plan"
        case .mcpDiscover:        return "MCP Discover"
        case .mcpBuilder:         return "MCP Builder"
        }
    }
    
    private struct ContextTile: View {
        let iconName: String
        let title: String
        let detail: String
        let active: Bool
        let isCompressed: Bool
        
        init(iconName: String, title: String, detail: String, active: Bool, isCompressed: Bool = false) {
            self.iconName = iconName
            self.title = title
            self.detail = detail
            self.active = active
            self.isCompressed = isCompressed
        }
        
		@ObservedObject private var fontScale = FontScaleManager.shared
        private var fontPreset: FontScalePreset { fontScale.preset }
        
        var body: some View {
            HStack(spacing: 6 * fontPreset.scaleFactor) {
                Image(systemName: iconName)
                    .font(.system(size: 12 * fontPreset.scaleFactor))
                    .foregroundColor(isCompressed ? .green : (active ? .accentColor : .secondary))
                    .frame(width: 16 * fontPreset.scaleFactor, height: 16 * fontPreset.scaleFactor)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading, spacing: 2 * fontPreset.scaleFactor) {
                    Text(title)
                        .font(fontPreset.captionFont.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Text(detail)
                        .font(fontPreset.captionFont)
                        .foregroundColor(active ? .secondary : .secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
			.padding(.horizontal, fontPreset.scaledClamped(6, min: 6, max: 9))
			.padding(.vertical, fontPreset.scaledClamped(5, min: 5, max: 8))
            .background(
                Color(nsColor: .controlBackgroundColor)
                    .opacity(isCompressed ? 0.5 : (active ? 0.45 : 0.25))
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCompressed ? Color.green.opacity(0.5) : (active ? Color(NSColor.systemGray).opacity(0.4) : Color(NSColor.systemGray).opacity(0.25)), lineWidth: isCompressed ? 1 : 0.5)
            )
        }
    }
}

struct ChatPresetPreviewView: View {
    let preset: ChatPreset
    let fontPreset: FontScalePreset
	@ObservedObject var promptViewModel: PromptViewModel
    @State private var showProEditSettings = false
    
    private var presetSubtitle: String {
        if preset.isBuiltIn {
            return ChatPresetManager.shared.hasOverrides(preset.id) ? "Built-in (modified)" : "Built-in preset"
        } else {
            return "Custom preset"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header - matching Copy preset style
            HStack {
                if let icon = preset.icon, !icon.isEmpty {
                    Text(icon)
                        .font(.system(size: 24))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.primary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(fontPreset.headlineFont)
                        .foregroundColor(.primary)
                    Text(presetSubtitle)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
				// Pro Edit config button
				if preset.mode == .proEdit {
                    Button {
                        showProEditSettings.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                            Text("Pro Edit Config")
                                .font(fontPreset.standardFont)
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .popover(isPresented: $showProEditSettings) {
                        ProEditSettingsView(promptViewModel: promptViewModel)
                            .frame(width: 475, height: 380)
                            .padding()
                    }
                }
            }
            
            // Context Configuration grid - similar to Copy preset's Context Overview
            VStack(alignment: .leading, spacing: 8) {
                Text("Context Configuration")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                
                LazyVGrid(columns: chatGridColumns, alignment: .leading, spacing: 10) {
                    // Chat Mode tile (prominently displayed)
                    ChatModeTile(
                        iconName: chatModeIcon(for: preset.mode),
                        title: "Mode",
                        detail: preset.mode.displayName,
                        active: true,
                        accentColor: chatModeColor(for: preset.mode)
                    )
                    
                    // Context source tile - always reflects current selection
                    ChatModeTile(
                        iconName: "doc.on.doc",
                        title: "Selected Files",
                        detail: "Current selection",
                        active: true
                    )
                    
                    // Show chat preset's own overrides only
                    if let fileTreeMode = preset.fileTreeMode {
                        ChatModeTile(
                            iconName: fileTreeIcon(for: fileTreeMode),
                            title: "File Tree",
                            detail: fileTreeMode.rawValue,
                            active: fileTreeMode != .none
                        )
                    }

                    if let codeMapUsage = preset.codeMapUsage {
                        ChatModeTile(
                            iconName: codeMapUsage != .none ? codeMapIcon(for: codeMapUsage) : "xmark.circle",
                            title: "Code Map",
                            detail: codeMapUsage != .none ? codeMapUsage.rawValue : "Excluded",
                            active: codeMapUsage != .none
                        )
                    }

                    if let gitInclusion = preset.gitInclusion {
                        ChatModeTile(
                            iconName: gitIcon(for: gitInclusion),
                            title: "Git Diff",
                            detail: gitInclusion.rawValue,
                            active: gitInclusion != .none
                        )
                    }
                    
                    // Model info in subtitle if specified
                    if let modelName = preset.modelPresetName,
                       let model = AIModel.fromModelName(modelName) {
                        ChatModeTile(
                            iconName: "cpu",
                            title: "Model",
                            detail: truncatedModelName(model.displayName),
                            active: true
                        )
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.systemGray).opacity(0.25), lineWidth: 0.5)
            )
            
            Divider()
            
            // When to use
            VStack(alignment: .leading, spacing: 6) {
                Text("When to use")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                Text(chatWhenToUseDescription)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // About this mode - matching Copy preset style
            VStack(alignment: .leading, spacing: 6) {
                Text("About this mode")
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                Text(chatModeDescription)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // Grid layout - fixed 2 columns for consistent display
    private var chatGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(), spacing: 10, alignment: .topLeading)
        ]
    }
    
    private func truncatedModelName(_ name: String) -> String {
        // Shorten common model names for better display
        if name.contains("claude") {
            return name.replacingOccurrences(of: "claude-", with: "")
        }
        if name.count > 20 {
            return String(name.prefix(18)) + "…"
        }
        return name
    }
    
    private func chatModeIcon(for mode: ChatPresetMode) -> String {
        switch mode {
        case .chat: return "bubble.left.and.bubble.right"
        case .plan: return "map"
        case .edit: return "pencil"
        case .proEdit: return "bolt.fill"
        case .review: return "magnifyingglass"
        }
    }
    
    private func chatModeColor(for mode: ChatPresetMode) -> Color {
        switch mode {
        case .chat: return .blue
        case .plan: return .purple
        case .edit: return .orange
        case .proEdit: return .green
        case .review: return .teal
        }
    }
    
    private func fileTreeIcon(for mode: FileTreeOption) -> String {
        switch mode {
        case .auto:
            return "arrow.triangle.2.circlepath.circle"
        case .files:
            return "list.bullet.rectangle"
		case .selected:
            return "target"
        case .none:
            return "xmark.circle"
        }
    }
    
    private func codeMapIcon(for usage: CodeMapUsage) -> String {
        switch usage {
        case .auto:
            return "arrow.triangle.2.circlepath.circle"
        case .complete:
            return "checkmark.circle.fill"
        case .selected:
            return "target"
        case .none:
            return "xmark.circle"
        }
    }
    
    private func gitIcon(for inclusion: GitInclusion) -> String {
        switch inclusion {
        case .none:
            return "circle"
        case .selected:
            return "smallcircle.filled.circle"
        case .complete:
            return "circle.fill"
        }
    }
    
    private var chatWhenToUseDescription: String {
        // Check if this is a built-in preset with specific use cases
        if preset.name == "Standard" {
            return "• General discussions and exploration\n• Understanding existing code\n• Debugging and troubleshooting"
        } else if preset.name == "Plan" {
            return "• Complex features needing design\n• Architecture decisions required\n• Multi-step implementation planning"
        } else if preset.name == "Edit" {
            return "• Direct code modifications\n• Focused implementation tasks\n• Clear requirements ready to code"
        } else if preset.name == "Manual" {
            return "• Custom workflow requirements\n• Full control over context\n• Advanced configuration needs"
        } else if preset.name == "XML Edit" {
            return "• Multi-file search-replace edits\n• Reviewable XML diff blocks\n• Works best with frontier models"
		} else if preset.mode == .proEdit {
            return "• Large multi-file changes\n• Need faster response times\n• Want higher edit accuracy"
        } else if preset.name == "Manual (XML)" {
            return "• Add custom prompts to XML editing\n• Want XML format with meta prompts\n• Full control over context"
        } else if preset.name == "Diff Follow-Up" {
            return "• Track progress against external plan\n• Verify changes align with strategy\n• Review recent commits"
        } else if preset.name == "Review" {
            return "• Code review sessions\n• Quality assessments\n• Pre-merge checks"
        } else if preset.name == "MCP Agent" {
			return "• Prime Claude Code/Codex agents\n• Complex multi-step workflows\n• Efficient context with codemaps"
        } else if preset.name == "MCP Pair" {
            return "• Complex features needing accuracy\n• Dual-model accountability\n• Extended context retention"
        } else if preset.name == "MCP Discover" {
			return "• Identifying required context for task\n• Setting up file selection\n• Generating context reports"
        }
        
        // Fallback based on chat mode
        switch preset.mode {
        case .chat:
            return "• Interactive discussions\n• Code exploration\n• Debugging sessions"
        case .plan:
            return "• Implementation planning\n• Architecture design\n• Task breakdown"
        case .edit:
            return "• Direct code changes\n• Focused implementation\n• Clear requirements"
        case .proEdit:
            return "• Large multi-file changes\n• Need faster response times\n• Want higher edit accuracy"
        case .review:
            return "• Code review with git diffs\n• Change analysis\n• Quality feedback"
        }
    }
    
    private var chatModeDescription: String {
        let baseDescription: String
        switch preset.mode {
        case .chat:
            baseDescription = "Unconstrained chat focused on file context. Steerable via Meta Prompts."
        case .plan:
            baseDescription = "Focused architectural planning from file context."
        case .edit:
            baseDescription = "Direct code editing. Requires powerful model capable of search/replace."
        case .proEdit:
            baseDescription = "Delegates edits to API models for faster output and higher accuracy on complex changes."
        case .review:
            baseDescription = "Code review mode with git diff context for analyzing changes."
        }
        
        // Add context source information — chat presets do not link copy presets
        let contextInfo = " Uses your current file selection and workspace settings."
        
        return baseDescription + contextInfo
    }
    
    private func contextIndicator(_ label: String, enabled: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundColor(enabled ? .green : .secondary)
                .font(.system(size: 10))
            Text(label)
                .font(fontPreset.captionFont)
                .foregroundColor(enabled ? .primary : .secondary)
        }
    }
    
    private func settingRow(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
            Text(value)
                .font(fontPreset.captionFont)
                .foregroundColor(.primary)
        }
    }
}

// Chat Mode Tile - similar to ContextTile but adapted for chat presets
private struct ChatModeTile: View {
    let iconName: String
    let title: String
    let detail: String
    let active: Bool
    var accentColor: Color? = nil
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    var body: some View {
        HStack(spacing: 6 * fontPreset.scaleFactor) {
            Image(systemName: iconName)
                .font(.system(size: 12 * fontPreset.scaleFactor))
                .foregroundColor(accentColor ?? (active ? .accentColor : .secondary))
                .frame(width: 16 * fontPreset.scaleFactor, height: 16 * fontPreset.scaleFactor)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2 * fontPreset.scaleFactor) {
                Text(title)
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text(detail)
                    .font(fontPreset.captionFont)
                    .foregroundColor(active ? .secondary : .secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
		.padding(.horizontal, fontPreset.scaledClamped(6, min: 6, max: 9))
		.padding(.vertical, fontPreset.scaledClamped(5, min: 5, max: 8))
        .background(
            Color(nsColor: .controlBackgroundColor)
                .opacity(active ? 0.45 : 0.25)
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor?.opacity(0.3) ?? (active ? Color(NSColor.systemGray).opacity(0.4) : Color(NSColor.systemGray).opacity(0.25)), lineWidth: 0.5)
        )
    }
}

// MARK: - Styled capsules and buttons (unchanged from your original)

/// Reusable capsule-styled label with hover background and border
private struct StyledCapsuleLabel<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let isHovering: Bool
    let label: () -> Label

    private var backgroundColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.75)
    }
    private var disabledColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.25)
    }
    private var lineColor: Color {
        Color(NSColor.systemGray)
    }

    var body: some View {
        label()
            .background(backgroundForState)
            .foregroundColor(isEnabled ? foregroundColor : .gray)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var backgroundForState: some View {
        if isEnabled {
            capsuleBackground
        } else {
            disabledColor
        }
    }

    private var capsuleBackground: some View {
        Group {
            if isHovering {
                backgroundColor.overlay(Color.primary.opacity(0.05))
            } else {
                Color.clear
            }
        }
    }

    private var borderColor: Color {
        if !isEnabled {
            return lineColor.opacity(0.25)
        }
        if isHovering {
            return lineColor
        }
        return lineColor.opacity(0.75)
    }

    private var foregroundColor: Color {
        Color(NSColor.labelColor)
    }
}

/// ButtonStyle that mirrors DualActionButton's look-and-feel
private struct BarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isHovering: Bool

    private var backgroundColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.75)
    }
    private var disabledColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.25)
    }
    private var lineColor: Color {
        Color(NSColor.systemGray)
    }
    private var foregroundColor: Color {
        Color(NSColor.labelColor)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(backgroundForState(configuration.isPressed))
            .foregroundColor(isEnabled ? foregroundColor : .gray)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColorForState(configuration.isPressed), lineWidth: 0.5)
            )
    }

    private func backgroundForState(_ pressed: Bool) -> some View {
        Group {
            if !isEnabled {
                disabledColor
            } else if pressed {
                backgroundColor.overlay(Color.primary.opacity(0.15))
            } else if isHovering {
                backgroundColor.overlay(Color.primary.opacity(0.05))
            } else {
                Color.clear
            }
        }
    }

    private func borderColorForState(_ pressed: Bool) -> Color {
        if !isEnabled {
            return lineColor.opacity(0.25)
        } else if pressed {
            return lineColor.opacity(0.5)
        } else if isHovering {
            return lineColor
        } else {
            return lineColor.opacity(0.75)
        }
    }
}
