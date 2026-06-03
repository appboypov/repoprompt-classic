import SwiftUI
import AppKit

// MARK: - ActionColumn
/// A cohesive vertical stack for a primary action (Copy/Chat),
/// a subtle token pill, and a preset selector that opens a popover.
struct ActionColumn<PickerContent: View>: View {
    enum Role { case copy, chat }
    
    let role: Role
    let mainIcon: String
    let mainLabel: String
    let onPrimaryAction: () -> Void
    
    // Token info
    let approxTokensText: String // e.g. "~12.5k tokens"
    let totalTokens: Int
    let tokenHelp: String
    
    // Preset selector
    let presetLabel: String
    @Binding var showPicker: Bool
    @ViewBuilder let pickerContent: () -> PickerContent
    
    // Optional keyboard shortcut for the main button
    let mainShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    var body: some View {
        let spacing = 6 * fontPreset.scaleFactor
        
        VStack(spacing: spacing) {
            // 1) Primary action
			PrimaryActionButtonWithFeedback(
				icon: mainIcon,
				label: mainLabel,
				action: onPrimaryAction,
				shortcut: mainShortcut
			)
            
            // 2) Token pill (subtle by default; colored only on warning/error)
            TokenPillView(
                approxText: approxTokensText,
                totalTokens: totalTokens,
                helpText: tokenHelp
            )
            
            // 3) Preset selector (opens two‑pane picker)
            PresetSelectorButton(text: presetLabel) {
                showPicker.toggle()
            }
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                pickerContent()
            }
        }
		
    }
}

struct UnifiedActionButton: View {
    enum Role { case copy, chat }
    
    // Role (determines animated feedback for copy)
    let role: Role
    
    // Top segment (action)
    let mainIcon: String
    let mainLabel: String
    let onPrimaryAction: () -> Void
    let mainShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    
    // Bottom segment (token + preset click area)
    let approxTokensText: String
    let totalTokens: Int
    let helpText: String
    let presetText: String
    let onOpenPreset: () -> Void
    let showTokenSummary: Bool = true  // NEW: allow hiding the inline token readout
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isHoveringTop = false
    @State private var isHoveringBottom = false
    @State private var isSuccessful = false
    
    private var segmentHeight: CGFloat { max(28 * fontPreset.scaleFactor, 24) }
    private let dividerThickness: CGFloat = 1.0
    
    // Styling colours (aligned with app look)
    private var backgroundColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.75) }
    private var disabledColor: Color  { Color(nsColor: .controlBackgroundColor).opacity(0.25) }
    private var lineColor: Color      { Color(NSColor.systemGray) }
    private var foregroundColor: Color { Color(NSColor.labelColor) }
    
    
    var body: some View {
        VStack(spacing: 0) {
            // TOP SEGMENT: main action (Copy w/ feedback; Chat basic)
            Button(action: performPrimaryAction) {
                HStack(spacing: 6) {
                    Image(systemName: isSuccessful ? "checkmark" : mainIcon)
                        .font(fontPreset.captionFont.weight(.medium))
                        .scaleEffect(isSuccessful ? 1.08 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSuccessful)
                    Text(mainLabel)
                        .font(fontPreset.standardFont)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: segmentHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .applyKeyboardShortcut(mainShortcut)
            .onHover { isHoveringTop = $0 }
            .accessibilityLabel(mainLabel)
            
            // Divider with no gap
            Divider()
                .frame(height: dividerThickness)
            
            // BOTTOM SEGMENT: token + preset inline selector
            Button(action: onOpenPreset) {
                HStack(spacing: 4 * fontPreset.scaleFactor) {
					Spacer()
                    // CPU icon on the left
                    Image(systemName: "cpu")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    
                    // Separator dot
                    Text("•")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                    
                    // Preset text in the center
                    Text(presetText)
                        .font(fontPreset.standardFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer()
                    
                    // Chevron on the right
                    Image(systemName: "chevron.down")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: segmentHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringBottom = $0 }
            .help(helpText)
            .accessibilityLabel("Preset selector and token info")
        }
        .frame(maxWidth: .infinity)
        .background(containerBackground)
        .foregroundColor(isEnabled ? foregroundColor : .gray)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 0.5)
        )
		
    }
    
    // MARK: - Background and border with segment-aware hover overlays
    @ViewBuilder
    private var containerBackground: some View {
        VStack(spacing: 0) {
            // Top segment background
            Group {
                if !isEnabled {
                    disabledColor
                } else if isHoveringTop {
                    backgroundColor
                } else {
                    Color.clear
                }
            }
            .frame(height: segmentHeight)
            
            // Divider
            Color.clear
                .frame(height: dividerThickness)
            
            // Bottom segment background
            Group {
                if !isEnabled {
                    disabledColor
                } else if isHoveringBottom {
                    backgroundColor
                } else {
                    Color.clear
                }
            }
            .frame(height: segmentHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var borderColor: Color {
        if !isEnabled {
            return lineColor.opacity(0.25)
        } else if isHoveringTop || isHoveringBottom {
            return lineColor
        } else {
            return lineColor.opacity(0.75)
        }
    }
    
    // MARK: - Token severity colouring (subtle by default)
    private enum Severity { case neutral, warning, error }
    private var severity: Severity {
        if totalTokens > 100_000 { return .error }
        if totalTokens >= 50_000 { return .warning }
        return .neutral
    }
    private var tokenTextColor: Color {
        switch severity {
        case .neutral: return .secondary
        case .warning: return .orange
        case .error:   return .red
        }
    }
    
    // MARK: - Actions
    private func performPrimaryAction() {
        if role == .copy {
            onPrimaryAction()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isSuccessful = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSuccessful = false
                }
            }
        } else {
            onPrimaryAction()
        }
    }
}
// MARK: - PrimaryActionButtonWithFeedback (Copy)
// Animated checkmark feedback on success
struct PrimaryActionButtonWithFeedback: View {
    let icon: String
    let successIcon: String = "checkmark"
    let label: String
    let action: () -> Void
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers)?

        @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }

	@State private var isHovering = false
	@State private var isSuccessful = false
	@State private var resetWorkItem: DispatchWorkItem?
	@State private var resetWorkGate = WorkItemGate()

    var body: some View {
        Button(action: performAction) {
            HStack(spacing: 6) {
                Image(systemName: isSuccessful ? successIcon : icon)
                    .font(fontPreset.captionFont.weight(.medium))
                    .scaleEffect(isSuccessful ? 1.08 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSuccessful)
                Text(label)
                    .font(fontPreset.standardFont)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: max(28 * fontPreset.scaleFactor, 24))
            .contentShape(Rectangle())
        }
        .buttonStyle(PrimaryActionButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .applyKeyboardShortcut(shortcut)
        .accessibilityLabel(label)
		.onDisappear {
			resetWorkItem?.cancel()
			resetWorkItem = nil
			resetWorkGate.cancel()
		}
	}

	private func performAction() {
		resetWorkItem?.cancel()
		resetWorkItem = nil
		resetWorkGate.cancel()

        action()

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            isSuccessful = true
        }

		resetWorkItem = resetWorkGate.schedule(after: 1.2) {
			withAnimation(.easeInOut(duration: 0.2)) {
				isSuccessful = false
			}
		}
	}
}

// MARK: - PrimaryActionButton (Chat)
// Regular CTA with the same style but no success animation
struct PrimaryActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(fontPreset.captionFont.weight(.medium))
                Text(label)
                    .font(fontPreset.standardFont)
                    .lineLimit(1)
            }
            .frame(height: max(28 * fontPreset.scaleFactor, 24))
            .contentShape(Rectangle())
        }
        .buttonStyle(PrimaryActionButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .applyKeyboardShortcut(shortcut)
        .accessibilityLabel(label)
    }
}

// MARK: - TokenPillView
/// Subtle gray by default; color only when warning or error thresholds are exceeded.
/// Uses the same thresholds as elsewhere in the app, but avoids bright green.
struct TokenPillView: View {
    let approxText: String
    let totalTokens: Int
    let helpText: String
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    @State private var isHovering = false
    
    private enum Severity { case neutral, warning, error }
    
    private var severity: Severity {
        if totalTokens > 100_000 { return .error }
        if totalTokens >= 50_000 { return .warning }
        return .neutral
    }
    
    var body: some View {
        HStack(spacing: 6 * fontPreset.scaleFactor) {
            Image(systemName: "cpu")
                .font(fontPreset.captionFont)
                .foregroundColor(textColor)
            Text(approxText)
                .font(fontPreset.captionFont)
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            backgroundColor
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel("Approximate token total \(approxText)")
    }
    
    // MARK: - Colors
    private var textColor: Color {
        switch severity {
        case .neutral: return .secondary
        case .warning: return Color.orange
        case .error:   return Color.red
        }
    }
    
	// Use @ViewBuilder to handle different return types
	@ViewBuilder
    private var backgroundColor: some View {
        let base = Color(nsColor: .controlBackgroundColor)
        switch severity {
        case .neutral:
			base.opacity(isHovering ? 0.65 : 0.5)
        case .warning:
			base.opacity(0.45).overlay(Color.orange.opacity(0.12))
        case .error:
			base.opacity(0.45).overlay(Color.red.opacity(0.15))
        }
    }
    
    private var borderColor: Color {
        switch severity {
        case .neutral:
            return Color(NSColor.systemGray).opacity(isHovering ? 0.6 : 0.4)
        case .warning:
            return Color.orange.opacity(isHovering ? 0.65 : 0.45)
        case .error:
            return Color.red.opacity(isHovering ? 0.7 : 0.5)
        }
    }
}

// MARK: - PresetSelectorButton
/// Capsule-styled button with chevron for opening preset pickers.
/// Separate click target from the main action button.
struct PresetSelectorButton: View {
    let text: String
    let onTap: () -> Void
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    
    private var backgroundColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.75) }
    private var disabledColor: Color  { Color(nsColor: .controlBackgroundColor).opacity(0.25) }
    private var lineColor: Color      { Color(NSColor.systemGray) }
    private var foregroundColor: Color { Color(NSColor.labelColor) }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(text)
                    .font(fontPreset.standardFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: max(28 * fontPreset.scaleFactor, 24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Group {
                if !isEnabled {
                    disabledColor
                } else if isHovering {
                    backgroundColor.overlay(Color.primary.opacity(0.05))
                } else {
                    Color.clear
                }
            }
        )
        .foregroundColor(isEnabled ? foregroundColor : .gray)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isEnabled
                    ? (isHovering ? lineColor : lineColor.opacity(0.75))
                    : lineColor.opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(text)
    }
}

// MARK: - PrimaryActionButtonStyle
/// Mirrors the look-and-feel of BarButtonStyle to keep primary actions consistent.
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isHovering: Bool
    
    private var backgroundColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.75) }
    private var disabledColor: Color  { Color(nsColor: .controlBackgroundColor).opacity(0.25) }
    private var lineColor: Color      { Color(NSColor.systemGray) }
    private var foregroundColor: Color { Color(NSColor.labelColor) }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Group {
                    if !isEnabled {
                        disabledColor
                    } else if configuration.isPressed {
                        backgroundColor.overlay(Color.primary.opacity(0.15))
                    } else if isHovering {
                        backgroundColor.overlay(Color.primary.opacity(0.05))
                    } else {
                        Color.clear
                    }
                }
            )
            .foregroundColor(isEnabled ? foregroundColor : .gray)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColorForState(configuration.isPressed), lineWidth: 0.5)
            )
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

// MARK: - Optional keyboard shortcut helper
fileprivate struct KeyboardShortcutModifier: ViewModifier {
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers)
    
    func body(content: Content) -> some View {
        content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}

fileprivate extension View {
    /// Applies a keyboard shortcut if provided (convenience for optional shortcuts).
    func applyKeyboardShortcut(_ shortcut: (key: KeyEquivalent, modifiers: EventModifiers)?) -> some View {
        guard let shortcut = shortcut else {
            return AnyView(self)
        }
        return AnyView(self.modifier(KeyboardShortcutModifier(shortcut: shortcut)))
    }
}

// MARK: - IntegratedActionComponent
struct IntegratedActionComponent<PickerContent: View>: View {
    enum Role { case copy, chat }
    
    let role: Role
    let mainIcon: String
    let mainLabel: String
    let onPrimaryAction: () -> Void
    
    // Token info
    let approxTokensText: String // e.g. "~12.5k tokens"
    let totalTokens: Int
    let tokenHelp: String
    
    // Preset selector (inline)
    let presetLabel: String  // e.g., "Copy: Manual" or "Chat: Chat"
    @Binding var showPicker: Bool
    @ViewBuilder let pickerContent: () -> PickerContent
    
    // Optional keyboard shortcut for the main button
    let mainShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    private var spacing: CGFloat { 8 * fontPreset.scaleFactor }
    
    var body: some View {
        HStack(spacing: spacing) {
            // Left: Primary action (animated for Copy; regular for Chat)
            if role == .copy {
                PrimaryActionButtonWithFeedback(
                    icon: mainIcon,
                    label: mainLabel,
                    action: onPrimaryAction,
                    shortcut: mainShortcut
                )
            } else {
                PrimaryActionButton(
                    icon: mainIcon,
                    label: mainLabel,
                    action: onPrimaryAction,
                    shortcut: mainShortcut
                )
            }
            
            // Right: inline preset + token selector area (distinct click target)
            PresetInlineSelector(
                presetText: presetLabel,
                approxTokensText: approxTokensText,
                totalTokens: totalTokens,
                helpText: tokenHelp
            ) {
                showPicker.toggle()
            }
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                pickerContent()
            }
        }
		
    }
}

// MARK: - PresetInlineSelector
private struct PresetInlineSelector: View {
    let presetText: String
    let approxTokensText: String
    let totalTokens: Int
    let helpText: String
    let onTap: () -> Void
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    @Environment(\.isEnabled) private var isEnabled
    
    @State private var isHovering = false
    
    private var backgroundColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.6) }
    private var disabledColor: Color { Color(nsColor: .controlBackgroundColor).opacity(0.25) }
    private var lineColor: Color { Color(NSColor.systemGray) }
    private var foregroundColor: Color { Color(NSColor.labelColor) }
    
    private enum Severity { case neutral, warning, error }
    
    private var severity: Severity {
        if totalTokens > 100_000 { return .error }
        if totalTokens >= 50_000 { return .warning }
        return .neutral
    }
    
    private var tokenTextColor: Color {
        switch severity {
        case .neutral: return .secondary
        case .warning: return .orange
        case .error:   return .red
        }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6 * fontPreset.scaleFactor) {
                // Small token text (secondary by default)
                HStack(spacing: 3 * fontPreset.scaleFactor) {
                    Image(systemName: "cpu")
                        .font(fontPreset.captionFont)
                        .foregroundColor(tokenTextColor)
                        .accessibilityHidden(true)
                    Text(approxTokensText)
                        .font(fontPreset.captionFont)
                        .foregroundColor(tokenTextColor)
                        .truncationMode(.tail)
                }
                
                // Separator dot
                Text("•")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                
                // Preset label + chevron
                HStack(spacing: 4 * fontPreset.scaleFactor) {
                    Text(presetText)
                        .font(fontPreset.standardFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: max(28 * fontPreset.scaleFactor, 24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Group {
                if !isEnabled {
                    disabledColor
                } else if isHovering {
                    backgroundColor.overlay(Color.primary.opacity(0.05))
                } else {
                    Color.clear
                }
            }
        )
        .foregroundColor(isEnabled ? foregroundColor : .gray)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isEnabled
                    ? (isHovering ? lineColor : lineColor.opacity(0.75))
                    : lineColor.opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel("Preset selector and token info")
    }
}

// MARK: - VerticalActionComponent
struct VerticalActionComponent<PickerContent: View>: View {
    enum Role { case copy, chat }
    
    // Primary action
    let role: Role
    let mainIcon: String
    let mainLabel: String
    let onPrimaryAction: () -> Void
    
    // Token + preset (combined inline selector)
    let approxTokensText: String
    let totalTokens: Int
    let helpText: String
    let presetLabel: String
    
    // Popover for preset picker
    @Binding var showPicker: Bool
    @ViewBuilder let pickerContent: () -> PickerContent
    
    // Optional shortcut for primary action
    let mainShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    
	@ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    private var spacing: CGFloat { 6 * fontPreset.scaleFactor }
    
    var body: some View {
        VStack(spacing: spacing) {
            if role == .copy {
                PrimaryActionButtonWithFeedback(
                    icon: mainIcon,
                    label: mainLabel,
                    action: onPrimaryAction,
                    shortcut: mainShortcut
                )
            } else {
                PrimaryActionButton(
                    icon: mainIcon,
                    label: mainLabel,
                    action: onPrimaryAction,
                    shortcut: mainShortcut
                )
            }
            
            // Bottom: inline token + preset selector (single clickable area)
            PresetInlineSelector(
                presetText: presetLabel,
                approxTokensText: approxTokensText,
                totalTokens: totalTokens,
                helpText: helpText
            ) {
                showPicker.toggle()
            }
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                pickerContent()
            }
        }
		
    }
}
