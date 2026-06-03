import SwiftUI
import AppKit

/// A unified, fixed-height bottom bar with integrated preset selection and always-visible pref tags
/// - Fixed height (112pt scaled) with two rows
/// - Top row: Dual-action buttons for Copy/Chat with preset pickers, token count and summary on right
/// - Bottom row: Always-visible pref tags (locked for presets, editable for manual)
struct UnifiedPresetBar: View {
	// View models
	@ObservedObject var promptVM: PromptViewModel
	@ObservedObject var tokenCounter: TokenCountingViewModel
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var gitViewModel: GitViewModel

	// External actions
	var onCopyNow: () -> Void

	// Environment
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	// Popovers
	@State private var showCopyPopover = false

	// Toast
	@State private var showManualToast = false
	
	// Track actual available width from layout system
	@State private var actualWidth: CGFloat = 800

	private var unifiedHeight: CGFloat { fontPreset.scaledClamped(92, min: 92, max: 122) }

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .top) {
				mainBarContent

				if showManualToast {
					toastView
				}
			}
			.animation(.easeInOut(duration: 0.18), value: showManualToast)
			.onAppear {
				actualWidth = geometry.size.width
			}
			.onChange(of: geometry.size.width) { _, newWidth in
				let scale = NSScreen.main?.backingScaleFactor ?? 2
				let epsilon = 1.0 / scale
				if abs(newWidth - actualWidth) > epsilon {
					actualWidth = newWidth
				}
			}
		}
		.frame(height: unifiedHeight + 8)
	}

	private var horizontalSpacing: CGFloat { fontPreset.scaledClamped(12, min: 12, max: 16) }
	private var horizontalPadding: CGFloat { fontPreset.scaledClamped(12, min: 12, max: 16) }
	private var verticalPadding: CGFloat { fontPreset.scaledClamped(12, min: 12, max: 16) }
	private var barCornerRadius: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 20) }
	private var barBackgroundColor: Color {
		Color(nsColor: .controlBackgroundColor).opacity(0.08)
	}
	private var barBorderColor: Color {
		Color(NSColor.systemGray).opacity(0.18)
	}
	
	private var mainBarContent: some View {
		HStack(spacing: horizontalSpacing) {
			// LEFT: Token count indicator
			tokenIndicator
				.frame(maxWidth: fontPreset.scaledClamped(160, min: 160, max: 210), alignment: .leading)

			centerTagsAndTokensSection

			// RIGHT: Copy preset picker
			leftCopyButtonSection
				.frame(maxWidth: fontPreset.scaledClamped(160, min: 160, max: 210), alignment: .trailing)
		}
		.padding(.horizontal, horizontalPadding)
		.padding(.vertical, verticalPadding)
		.frame(height: unifiedHeight)
		.background(barBackgroundColor)
		.cornerRadius(barCornerRadius)
		.overlay(
			RoundedRectangle(cornerRadius: barCornerRadius)
				.stroke(barBorderColor, lineWidth: 0.5)
		)
		.padding(.bottom, 8)
	}

	private var tokenIndicator: some View {
		let total = tokenCounter.copyContextTotalTokens
		return HStack(spacing: 0) {
			Image(systemName: "number")
				.font(fontPreset.standardFont)
				.foregroundColor(tokenColor(total: total))

			Spacer()
				.frame(minWidth: 8, maxWidth: 12)

			Text("~\(formatApproxTokens(total)) tokens")
				.font(fontPreset.standardFont)
				.foregroundColor(tokenColor(total: total))
				.lineLimit(1)
				.minimumScaleFactor(0.85)

			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, fontPreset.scaledClamped(12, min: 12, max: 14))
		.padding(.vertical, fontPreset.scaledClamped(8, min: 8, max: 10))
		.frame(minHeight: fontPreset.scaledClamped(34, min: 34, max: 44))
		.background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
		.cornerRadius(16)
		.overlay(
			RoundedRectangle(cornerRadius: 16)
				.stroke(tokenColor(total: total).opacity(0.3), lineWidth: 1)
		)
		.help(tokenWarningHelpFor(total: total))
	}

	// MARK: - Token readout (legacy helper; unused in compact layout)
	private var tokenReadout: some View {
		let approx = tokenCounter.tokenCount
		return HStack(spacing: 6) {
			Image(systemName: "cpu").font(fontPreset.captionFont)
			Text("~\(approx) tokens")
				.font(fontPreset.headlineFont)
				.lineLimit(1)
				.truncationMode(.middle)
		}
		.foregroundColor(.secondary)
		.help(tokenWarningHelp)
		.accessibilityLabel("Approximate token total \(approx)")
	}

	private var leftCopyButtonSection: some View {
		let presetName = copyPresetName
		return UnifiedActionButton(
			role: .copy,
			mainIcon: "doc.on.clipboard",
			mainLabel: "Copy Prompt",
			onPrimaryAction: onCopyNow,
			mainShortcut: ("c", [.command, .shift]),
			approxTokensText: "",
			totalTokens: 0,
			helpText: "",
			presetText: presetName,
			onOpenPreset: { showCopyPopover.toggle() }
		)
		.frame(maxWidth: .infinity)
		.background(!isCopyManual ? Color.blue.opacity(0.05) : Color.clear)
		.cornerRadius(16)
		.overlay(
			RoundedRectangle(cornerRadius: 16)
				.stroke(!isCopyManual ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
		)
		.hoverTooltip("Copy preset: \(presetName)\n\(isCopyManual ? "Manual mode - Full control" : "Preset controls context settings")\n⌘⇧C to copy")
		.popover(isPresented: $showCopyPopover, arrowEdge: .bottom) {
			copyPresetPopoverContent()
		}
	}

	private var centerTagsAndTokensSection: some View {
		let isCompact = actualWidth < fontPreset.scaledClamped(654, min: 654, max: 760)
		return VStack(spacing: fontPreset.scaledClamped(6, min: 6, max: 8)) {
			// Main controls row - always show full controls
			// First row: File tree and scan files (or unified row when wide)
			if isCompact {
				HStack(spacing: fontPreset.scaledClamped(6, min: 6, max: 8)) {
					FileTreePrefTag(promptManager: promptVM, isLocked: false)
					ScanFilesPrefTag(
						fileManager: fileManager,
						promptManager: promptVM,
						isChatContext: false,
						isLocked: false
					)
				}
			} else {
				// Wide: put FileTree, Scan, Git, Prompts all on one line - centered
				HStack(spacing: fontPreset.scaledClamped(6, min: 6, max: 8)) {
					Spacer(minLength: 0)
					FileTreePrefTag(promptManager: promptVM, isLocked: false)
					ScanFilesPrefTag(
						fileManager: fileManager,
						promptManager: promptVM,
						isChatContext: false,
						isLocked: false
					)
					// Always show Git button
					GitPrefTag(
						gitViewModel: gitViewModel,
						promptManager: promptVM,
						context: .copy,
						gitDiffTokenCount: tokenCounter.gitDiffTokenCount,
						isLocked: false
					)
					PromptsButtonSection(promptVM: promptVM)

					Spacer(minLength: 0)
				}
			}

			// Second row: Git and Prompts on same line - centered (only for compact)
			if isCompact {
				HStack(spacing: fontPreset.scaledClamped(6, min: 6, max: 8)) {
					Spacer()

					// Always show Git button
					GitPrefTag(
						gitViewModel: gitViewModel,
						promptManager: promptVM,
						context: .copy,
						gitDiffTokenCount: tokenCounter.gitDiffTokenCount,
						isLocked: false
					)

					// Prompts button
					PromptsButtonSection(promptVM: promptVM)

					Spacer()
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	


	private var tokenWarningHelp: String {
		let breakdown = tokenCounter.tokenBreakdownDescription
		return breakdown.isEmpty ? "Current estimated token count" : "Current estimated token count\n\(breakdown)"
	}

	private func tokenWarningHelpFor(total: Int) -> String {
		let breakdown = tokenCounter.tokenBreakdownDescription
		return breakdown.isEmpty ? "Current estimated token count" : "Current estimated token count\n\(breakdown)"
	}

	private func formatApproxTokens(_ count: Int) -> String {
		if count >= 1_000_000 {
			let millions = Double(count) / 1_000_000.0
			return String(format: "%.2fm", millions)
		} else if count >= 1_000 {
			let thousands = Double(count) / 1_000.0
			return String(format: "%.2fk", thousands)
		} else {
			return "\(count)"
		}
	}

	@ViewBuilder
	private func copyPresetPopoverContent() -> some View {
		let presetsRaw = CopyPresetManager.shared.allPresets.filter { CopyPresetManager.shared.isPresetVisible($0) }
		let allCopyPresets = presetsRaw.isEmpty ? [BuiltInCopyPresets.standard] : presetsRaw
		let selectedId = promptVM.selectedCopyPresetID ?? BuiltInCopyPresets.standard.id
		
		PresetTwoPanePopover_Copy(
			allPresets: allCopyPresets,
			selectedId: selectedId,
			fontPreset: fontPreset,
			windowID: promptVM.windowID,
			previewBuilder: { preset in
				CopyPresetPreviewView(preset: preset, fontPreset: fontPreset, promptViewModel: promptVM)
			},
			onSelect: { preset in
				promptVM.selectCopyPreset(preset.id)
				showCopyPopover = false
			}
		)
		.frame(width: 640 * fontPreset.scaleFactor, height: 436 * fontPreset.scaleFactor)
		.padding(10)
	}

	// MARK: - Summary (right)
	private var presetSummary: some View {
		VStack(alignment: .trailing, spacing: 2) {
			EmptyView()
		}
	}


	// MARK: - Summary (legacy helpers no longer used for hover)
	private func copySummaryLine() -> String {
		let cfg = promptVM.resolvePromptContext(promptVM.currentCopyPreset(), custom: promptVM.workingCopyCustomizations)
		let copyPreset = promptVM.currentCopyPreset()
		return "Copy: \(copyPreset.name) • files=\(cfg.includeFiles ? "✓" : "✗") user=\(cfg.includeUserPrompt ? "✓" : "✗") meta=\(cfg.includeMetaPrompts ? "✓" : "✗") • tree=\(cfg.fileTreeMode.rawValue) map=\(cfg.codeMapUsage.rawValue) git=\(cfg.gitInclusion.rawValue)"
	}

	private func chatSummaryLine() -> String {
		let chat = promptVM.currentChatPreset()
		return "Chat: \(chat.name) • Mode: \(chat.mode.displayName)"
	}

	// Tooltips for buttons (not used in new layout but kept for compatibility)
	private func resolvedCopySummary() -> String {
		let cfg = promptVM.resolvePromptContext(promptVM.currentCopyPreset(), custom: promptVM.workingCopyCustomizations)
		let copyPreset = promptVM.currentCopyPreset()
		return """
        Copy Preset: \(copyPreset.name)
        Includes: files=\(cfg.includeFiles ? "yes" : "no"), user=\(cfg.includeUserPrompt ? "yes" : "no"), meta=\(cfg.includeMetaPrompts ? "yes" : "no")
        File Tree: \(cfg.fileTreeMode.rawValue)
        Code Map: \(cfg.codeMapUsage.rawValue)
        Git: \(cfg.gitInclusion.rawValue)
        XML: \(cfg.xmlFormat?.rawValue ?? "none")\(cfg.systemPromptFlavor.map { "\nSystem: \(String(describing: $0))" } ?? "")
        """
	}

	private func resolvedChatSummary() -> String {
		let chat = promptVM.currentChatPreset()
		return """
        Chat Preset: \(chat.name)
        Mode: \(chat.mode.displayName)
        """
	}

	private var toastView: some View {
		Text("Switched to Manual to allow customization")
			.font(fontPreset.captionFont)
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(Color.secondary.opacity(0.15))
			.cornerRadius(6)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
			)
			.transition(.opacity.combined(with: .move(edge: .top)))
			.padding(.top, 6)
	}

	private var isCopyManual: Bool {
		promptVM.currentCopyPreset().builtInKind == .manual
	}
	
	private var isGitUnlocked: Bool {
		// Git is unlocked if in manual mode OR if using a copy preset that includes git
		if isCopyManual {
			return true
		}
		
		// Check if current copy preset has git enabled
		let copyPreset = promptVM.currentCopyPreset()
		if let gitMode = copyPreset.gitInclusion,
           gitMode != .none {
			return true
		}
		
		// Don't check chat preset in the unified preset bar (prompt view)
		// This is the copy operation, not chat
		
		return false
	}
	
	private func tokenColor(total: Int) -> Color {
		if total > 100_000 { return .red }
		if total >= 50_000 { return .orange }
		return .secondary
	}

	// Precompute frequently used names to avoid repeated lookups
	private var copyPresetName: String { promptVM.currentCopyPreset().name }
}


// MARK: - Import the two-pane popovers from PresetBottomBar
// These are already defined in PresetBottomBar.swift, so we'll use them directly

// MARK: - Prompts Button Section
	private struct PromptsButtonSection: View {
	@ObservedObject var promptVM: PromptViewModel
	@State private var showStoredPrompts = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		Button {
			showStoredPrompts.toggle()
		} label: {
			HStack(spacing: 4) {
				Text("Prompts")
					.font(fontPreset.standardFont)
					.lineLimit(1)
					.minimumScaleFactor(0.85)
					.foregroundColor(.primary)
				
				Text("(\(totalPromptSelectionCount))")
					.foregroundColor(.secondary)
					.font(fontPreset.captionFont)
					.lineLimit(1)
			}
		}
		.buttonStyle(SelectorButtonStyle(hasSelection: totalPromptSelectionCount > 0))
		.popover(isPresented: $showStoredPrompts) {
			StoredPromptsOverlay(
				isVisible: $showStoredPrompts,
				context: .copy,
				promptManager: promptVM
			)
		}
	}
	
	private var totalPromptSelectionCount: Int {
		let resolved = promptVM.resolvePromptContext(promptVM.currentCopyPreset(), custom: promptVM.workingCopyCustomizations)

		// Count system flavor (if present) as 1
		let systemCount = resolved.systemPromptFlavor != nil ? 1 : 0

		// Count stored prompts (manual selections + preset-wired)
		var identifiers = Set(promptVM.selectedPromptIDs)
		if let presetIds = resolved.storedPromptIds {
			identifiers.formUnion(presetIds)
		}

		return systemCount + identifiers.count
	}
}
