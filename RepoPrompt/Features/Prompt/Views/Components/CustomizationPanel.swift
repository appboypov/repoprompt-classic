import SwiftUI

struct CustomizationPanel: View {
    @ObservedObject var promptVM: PromptViewModel
    @ObservedObject var fileManager: RepoFileManagerViewModel
    @ObservedObject var gitViewModel: GitViewModel
    
    /// When true (Manual preset), the panel is always visible.
    let isAlwaysVisible: Bool
    /// For non-manual presets, controls visibility.
    @Binding var showCustomization: Bool
    
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    var body: some View {
        Group {
            if isAlwaysVisible || showCustomization {
                VStack(alignment: .leading, spacing: 10) {
                    if !isAlwaysVisible {
                        Divider() // visually separate from the bar above when toggled
                    }
                    header
                    chipsRow
                    sections
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                // Embedded look: background/border handled by the parent bottom bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: showCustomization)
            }
        }
    }
    
    // MARK: - Header
    private var header: some View {
        let preset = promptVM.currentCopyPreset()
        return HStack(alignment: .center, spacing: 10) {
            if let icon = preset.icon, !icon.isEmpty {
                Text(icon)
                    .font(fontPreset.headlineFont)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(fontPreset.headlineFont)
                    .accessibilityHidden(true)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(fontPreset.headlineFont)
                if let desc = preset.description, !desc.isEmpty {
                    Text(desc)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isCustomized {
                Button {
                    resetToPresetDefaults()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Customizations")
                    }
                    .font(fontPreset.standardFont)
                }
                .buttonStyle(CustomizationBarButtonStyle(isHovering: false))
                .help("Reset settings to the selected preset defaults")
                .accessibilityLabel("Reset Customizations")
            }
        }
    }
    
    // MARK: - Chips Row
    private var chipsRow: some View {
        HStack(spacing: 8 * fontPreset.scaleFactor) {
            // File Tree chip
            FileTreeTagContent(
                fontPreset: fontPreset,
                isHovering: false,
                fileTreeOption: promptVM.fileTreeOption
            )
            .accessibilityLabel("File Tree settings")
            
            // Git chip
            GitTagContent(
                fontPreset: fontPreset,
                isHovering: false,
                isActive: gitViewModel.gitDiffInclusionMode != .none,
                selectedRootFolder: gitViewModel.selectedRootFolder,
                unstagedCount: gitViewModel.unstagedFiles.count,
                diffMode: gitViewModel.gitDiffInclusionMode,
                gitDiffTokenCount: promptVM.gitDiffTokenCount
            )
            .accessibilityLabel("Git settings")
            
            // Code Map chip
            CodeMapChip(
                promptVM: promptVM,
                fontPreset: fontPreset,
                isChatContext: promptVM.planActMode == .edit
            )
            .accessibilityLabel("Code Map settings")
            
            Spacer(minLength: 0)
        }
    }
    
    // MARK: - Sections
    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            // File Tree
			Section {
				FileTreeInlineSection(promptVM: promptVM, fontPreset: fontPreset, context: .copy)
            } header: {
                Text("File Tree")
                    .font(fontPreset.subheadlineFont)
            }
            
            // Git
			Section {
				GitInlineSection(gitViewModel: gitViewModel, promptVM: promptVM, fontPreset: fontPreset, context: .copy)
            } header: {
                Text("Git")
                    .font(fontPreset.subheadlineFont)
            }
            
            // Code Map
			Section {
				CodeMapInlineSection(
					fileManager: fileManager,
					promptVM: promptVM,
					context: .copy,
					fontPreset: fontPreset,
					isChatContext: promptVM.planActMode == .edit
				)
            } header: {
                Text("Code Map")
                    .font(fontPreset.subheadlineFont)
            }
        }
    }
    
    // MARK: - Customization Diff + Reset
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
    
    private func resetToPresetDefaults() {
        let preset = promptVM.currentCopyPreset()
        // Apply only fields explicitly defined on the preset; leave others unchanged
        if let ft = preset.fileTreeMode {
            promptVM.fileTreeOption = ft
            promptVM.markSettingsDirty()
        }
        if let cm = preset.codeMapUsage {
            promptVM.codeMapUsage = cm
            promptVM.markSettingsDirty()
        }
        if let gi = preset.gitInclusion {
            switch gi {
            case .none: gitViewModel.gitDiffInclusionMode = .none
            case .selected: gitViewModel.gitDiffInclusionMode = .selectedFiles
            case .complete: gitViewModel.gitDiffInclusionMode = .all
            }
        }
    }
}

// MARK: - Small styled button similar to DualActionButton
private struct CustomizationBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isHovering: Bool
    
    private var backgroundColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.75) }
    private var disabledColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.25) }
    private var lineColor: Color { Color(NSColor.systemGray) }
    private var foregroundColor: Color { Color(NSColor.labelColor) }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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

// MARK: - Minimal chip for Code Map (mirrors ScanPrefTag visuals)
private struct CodeMapChip: View {
    @ObservedObject var promptVM: PromptViewModel
    let fontPreset: FontScalePreset
    let isChatContext: Bool
    
	private var isGloballyDisabled: Bool {
		promptVM.codeMapsGloballyDisabled
	}
    private var isWarningState: Bool {
		return !isGloballyDisabled && isChatContext && promptVM.codeMapUsage == .selected && promptVM.planActMode == .edit
    }
    private var modeIconName: String {
		if isGloballyDisabled { return "slash.circle" }
        if isWarningState { return "exclamationmark.triangle.fill" }
        switch promptVM.codeMapUsage {
        case .auto: return "arrow.triangle.2.circlepath.circle"
        case .complete: return "checkmark.circle.fill"
        case .selected: return "target"
        case .none: return "xmark.circle"
        }
    }
	private var iconColor: Color {
		if isGloballyDisabled { return .orange }
		return isWarningState ? .yellow : .primary
	}
	private var backgroundColor: Color {
		if isGloballyDisabled { return Color.orange.opacity(0.1) }
		return isWarningState ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.1)
	}
	private var borderColor: Color {
		isGloballyDisabled ? Color.orange.opacity(0.35) : Color.gray.opacity(0.3)
	}
    
    var body: some View {
        HStack(spacing: 8 * fontPreset.scaleFactor) {
			Text(isGloballyDisabled ? "Code Map Disabled" : "Code Map")
                .font(fontPreset.font)
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Image(systemName: modeIconName)
                .font(.system(size: 12 * fontPreset.scaleFactor))
                .frame(width: 16 * fontPreset.scaleFactor, height: 16 * fontPreset.scaleFactor)
				.foregroundColor(iconColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
		.background(backgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
				.stroke(borderColor, lineWidth: 1)
        )
    }
}
