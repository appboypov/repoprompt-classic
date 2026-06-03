import SwiftUI

// MARK: - Agent Session Row

struct AgentSessionRow: View {
	let title: String
	let isActive: Bool
	let isPinned: Bool
	let isMCPControlled: Bool
	let runState: AgentSessionRunState
	let isWaiting: Bool
	/// When non-nil, the session raised a completed/failed/waiting transition
	/// while the user was NOT viewing it. Drives a persistent attention badge
	/// that survives re-renders until the session is selected/resumed or the
	/// user dismisses the badge explicitly.
	var attentionRunState: AgentSessionRunState? = nil
	let threadDepth: Int
	var hasThreadChildren: Bool = false
	var isThreadCollapsed: Bool = false
	var hiddenThreadDescendantCount: Int = 0
	/// Number of descendants hidden under this collapsed parent that carry
	/// an unseen run-state attention badge. When > 0 the hidden-count chip is
	/// tinted to mirror the mcp-status-style "something happened" cue.
	var hiddenThreadDescendantAttentionCount: Int = 0
	var onToggleThreadCollapse: (() -> Void)? = nil
	let onSelect: () -> Void
	let onTogglePin: () -> Void
	let onStash: () -> Void
	let onDelete: () -> Void
	let onRename: (String) -> Void
	var onDismissAttention: (() -> Void)? = nil
	
	@State private var isHovered = false
	@State private var isPinHovered = false
	@State private var isDeleteHovered = false
	@State private var isRenameHovered = false
	@State private var isStashHovered = false
	@State private var isDisclosureHovered = false
	@State private var isDismissAttentionHovered = false
	@State private var showRenameAlert = false
	@State private var showDeleteConfirmation = false
	@State private var renameText = ""
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	private var rowMinHeight: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 38) }
	private var rowHorizontalPadding: CGFloat { fontPreset.scaledClamped(10, max: 14) }
	private var rowVerticalPadding: CGFloat { fontPreset.scaledClamped(4, max: 7) }
	private var rowCornerRadius: CGFloat { fontPreset.scaledClamped(14, max: 18) }
	private var rowSpacing: CGFloat { fontPreset.scaledClamped(8, max: 11) }
	private var titlePinSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var titleVStackSpacing: CGFloat { fontPreset.scaledClamped(2, max: 3) }
	private var pinFontSize: CGFloat { fontPreset.scaledClamped(10, max: 13) }
	private var chipHorizontalPadding: CGFloat { fontPreset.scaledClamped(5, max: 7) }
	private var chipVerticalPadding: CGFloat { fontPreset.scaledClamped(1, max: 2) }
	
	private var leadingIndent: CGFloat {
		CGFloat(threadDepth) * fontPreset.scaledClamped(14, min: 14, max: 20)
	}

	private var showsDisclosureChevron: Bool {
		threadDepth == 0 && hasThreadChildren && onToggleThreadCollapse != nil
	}

	private var hiddenCountTooltip: String {
		let base = hiddenThreadDescendantCount == 1
			? "1 sub-agent chat hidden"
			: "\(hiddenThreadDescendantCount) sub-agent chats hidden"
		guard hiddenThreadDescendantAttentionCount > 0 else { return base }
		let suffix = hiddenThreadDescendantAttentionCount == 1
			? "1 needs attention"
			: "\(hiddenThreadDescendantAttentionCount) need attention"
		return base + " — " + suffix
	}

	private var disclosureAccessibilityLabel: String {
		isThreadCollapsed ? "Expand sub-agent chats" : "Collapse sub-agent chats"
	}

	var body: some View {
		HStack(spacing: rowSpacing) {
			if threadDepth > 0 {
				Spacer()
					.frame(width: leadingIndent)
			}

			// MCP-controlled cue is folded into the existing status plate
			// (orange-tinted dot/chevron + orange running arc) so it no
			// longer pushes the title sideways. See `mcpAccentColor`,
			// `plateGlyph`, and `AgentRowActivityArc(tint:)` below.

			// Unified 14pt status plate.
			//
			// One slot carries both the row's identity glyph (chevron for
			// expandable roots, arrow for sub-agents, anchor dot or attention
			// glyph for leaf roots) AND its run-state status (plate fill +
			// optional halo + optional running arc). Folding both into a
			// single slot keeps the title's leading X stable regardless of
			// run state — previously the title shifted ~14pt sideways when a
			// row transitioned in/out of running/waiting/failed.
			statusPlate

			// Session name
			VStack(alignment: .leading, spacing: titleVStackSpacing) {
				HStack(spacing: titlePinSpacing) {
					Text(title)
						.font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: isActive ? .semibold : .regular))
						.lineLimit(1)
						.truncationMode(.tail)

					if isPinned {
						Image(systemName: "pin.fill")
							.font(.system(size: pinFontSize))
							.foregroundStyle(.secondary)
					}

					if isThreadCollapsed && hiddenThreadDescendantCount > 0 {
						hiddenCountChip
					}
				}
			}
			
			Spacer()
			
			// Trailing indicator (checkmark or delete button)
			if isHovered {
				if attentionRunState != nil, let onDismissAttention {
					Button(action: onDismissAttention) {
						Image(systemName: "bell.slash")
							.font(.system(size: 11))
							.foregroundColor(isDismissAttentionHovered ? .accentColor : .secondary)
					}
					.buttonStyle(.plain)
					.onHover { isDismissAttentionHovered = $0 }
					.hoverTooltip("Dismiss status badge")
					.accessibilityLabel("Dismiss status badge")
				}

				Button(action: onTogglePin) {
					Image(systemName: isPinned ? "pin.slash" : "pin")
						.font(.system(size: 11))
						.foregroundColor(isPinHovered ? .accentColor : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isPinHovered = $0 }
				.hoverTooltip(isPinned ? "Unpin chat" : "Pin chat")

				Button {
					renameText = title
					showRenameAlert = true
				} label: {
					Image(systemName: "pencil")
						.font(.system(size: 11))
						.foregroundColor(isRenameHovered ? .accentColor : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isRenameHovered = $0 }
				.hoverTooltip("Rename chat")

				Button(action: onStash) {
					Image(systemName: "tray.and.arrow.down")
						.font(.system(size: 11))
						.foregroundColor(isStashHovered ? .accentColor : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isStashHovered = $0 }
				.hoverTooltip("Stash chat for later")
				
				Button {
					showDeleteConfirmation = true
				} label: {
					Image(systemName: "trash")
						.font(.system(size: 11))
						.foregroundColor(isDeleteHovered ? .red : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isDeleteHovered = $0 }
				.hoverTooltip("Delete chat")
			}
			// Selected state is already signaled by the accent-tinted background +
			// semibold title weight; a trailing checkmark was redundant.
		}
		.padding(.horizontal, rowHorizontalPadding)
		.padding(.vertical, rowVerticalPadding)
		.frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
		.background(
			Group {
				if isActive {
					RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
						.fill(Color.accentColor.opacity(0.15))
				} else if isHovered {
					RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
						.stroke(Color(NSColor.systemGray).opacity(0.5), lineWidth: 1)
				}
			}
		)
		.contentShape(Rectangle())
		.onHover { isHovered = $0 }
		.onTapGesture { onSelect() }
		.accessibilityLabel(title)
		.popover(isPresented: $showDeleteConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
			VStack(alignment: .leading, spacing: 12) {
				Text("Delete chat?")
					.font(.headline)
				Text("This permanently deletes this chat.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
				HStack {
					Spacer()
					Button("Cancel") {
						showDeleteConfirmation = false
					}
					Button("Delete") {
						showDeleteConfirmation = false
						onDelete()
					}
					.keyboardShortcut(.defaultAction)
				}
			}
			.padding()
			.frame(width: 280)
		}
		.sheet(isPresented: $showRenameAlert) {
			AgentSessionRenameSheet(
				renameText: $renameText,
				onConfirm: { newName in
					showRenameAlert = false
					onRename(newName)
				},
				onCancel: {
					showRenameAlert = false
				}
			)
		}
	}
	
	/// True when this row should advertise that it was opened by an
	/// external MCP client. Only root rows wear this cue — sub-agent
	/// rows are always MCP-driven by their parent, so the indent + arrow
	/// glyph already convey the same meaning.
	private var isMCPControlledRoot: Bool {
		isMCPControlled && threadDepth == 0
	}

	private var hiddenCountChip: some View {
		let hasHiddenAttention = hiddenThreadDescendantAttentionCount > 0
		return Text("\(hiddenThreadDescendantCount)")
			.font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: hasHiddenAttention ? .semibold : .medium))
			.foregroundStyle(hasHiddenAttention ? Color.orange : Color.secondary)
			.padding(.horizontal, chipHorizontalPadding)
			.padding(.vertical, chipVerticalPadding)
			.background(
				Capsule()
					.fill(
						hasHiddenAttention
							? Color.orange.opacity(0.18)
							: Color(NSColor.systemGray).opacity(0.18)
					)
			)
			.overlay(
				Capsule()
					.stroke(Color.orange.opacity(hasHiddenAttention ? 0.6 : 0), lineWidth: 1)
			)
			.hoverTooltip(hiddenCountTooltip)
			.accessibilityLabel(hiddenCountTooltip)
	}

	/// The state the status slot should visually reflect.
	///
	/// Rules:
	/// - Running always wins (live activity outranks any stale attention).
	/// - Otherwise prefer the unseen attention state (mirrors the MCP status
	///   "inactive/active/attention" pattern — attention is the "look at me"
	///   signal and trumps steady-state).
	/// - Fall back to the current run state.
	private var effectiveStatusState: AgentSessionRunState {
		if runState == .running { return .running }
		if let attentionRunState { return attentionRunState }
		return runState
	}

	/// True when the current signal is a background transition the user
	/// hasn't acknowledged yet. Drives the stronger "badge" treatment.
	private var isUnseenAttention: Bool {
		guard let attentionRunState else { return false }
		// If the row is currently running we prefer to show the running arc
		// rather than a stale attention ring — attention will re-raise when
		// this run terminates.
		if runState == .running { return false }
		return AgentSessionSidebarUIStore.isAttentionEligible(attentionRunState)
	}

	/// Shared accent used to flag MCP-controlled root rows in the status
	/// plate. Orange is the same hue used elsewhere for MCP affordances
	/// (file drawer chips, in-progress streaming badge, etc).
	private static let mcpAccentColor = Color.orange

	// MARK: - Unified status plate
	//
	// Single 14pt leading slot that carries BOTH row identity (chevron /
	// arrow / anchor dot / attention glyph) AND run-state status (plate
	// fill tint + optional halo stroke + optional running arc overlay).
	//
	// Status vocabulary:
	//   - idle / cancelled     → clear plate, leaf rows show a hairline dot
	//   - running              → accent-tinted plate + rotating arc overlay,
	//                            identity glyph remains inside
	//   - waiting (*)          → green-tinted plate; unseen raises to a
	//                            louder halo stroke ("needs you" cue)
	//   - completed + unseen   → green-tinted plate + checkmark glyph
	//   - failed               → red-tinted plate; unseen swaps the glyph
	//                            for an exclamation mark
	//
	// The identity glyph (chevron / arrow / dot) is preserved except when
	// a strong background-attention cue requires a dedicated state glyph
	// (checkmark for unseen-completed, exclamationmark for unseen-failed).
	// This way the plate always reserves 14pt of leading width and the
	// title's X offset is a pure function of threadDepth.
	@ViewBuilder
	private var statusPlate: some View {
		ZStack {
			// Status-encoding fill tint. Stays decorative so the chevron
			// button's hit test isn't blocked.
			Circle()
				.fill(plateFillColor)
				.allowsHitTesting(false)

			// Louder halo for unseen waiting states — preserves the pre-
			// refactor "green halo ring" cue that tells the user a
			// background session is waiting on them.
			if showsWaitingHalo {
				Circle()
					.stroke(Color.green.opacity(0.55), lineWidth: 1.5)
					.allowsHitTesting(false)
			}

			// Spinning arc overlay while a run is live. Sits between the
			// plate fill and the identity glyph so the chevron/arrow/dot
			// remains visually centered while the ring conveys motion.
			if runState == .running {
				AgentRowActivityArc(tint: runningAccentColor)
					.allowsHitTesting(false)
			}

			// Foreground glyph — identity for normal states, attention
			// glyph when an unseen background transition demands it.
			plateGlyph
		}
		.frame(width: 16, height: 16)
		.hoverTooltip(plateTooltip)
		.accessibilityLabel(plateAccessibilityLabel)
	}

	/// Tint used for the running arc and the running plate fill. Orange
	/// for MCP-controlled root rows so the running cue rhymes with the
	/// rest of the MCP indicators; default accent everywhere else.
	private var runningAccentColor: Color {
		isMCPControlledRoot ? Self.mcpAccentColor : Color.accentColor
	}

	/// Background tint that encodes the row's effective run state. Kept
	/// at low alpha so the plate reads as a tint, not a loud chip.
	private var plateFillColor: Color {
		switch effectiveStatusState {
		case .running:
			// No disc behind the running arc — the rotating arc reads cleanly
			// on its own and the faint accent fill clashed with the centered
			// dot. Keep the plate transparent so only the arc + glyph show.
			return .clear
		case .waitingForUser, .waitingForQuestion, .waitingForApproval:
			return Color.green.opacity(isUnseenAttention ? 0.22 : 0.15)
		case .completed:
			return isUnseenAttention ? Color.green.opacity(0.18) : .clear
		case .failed:
			return Color.red.opacity(isUnseenAttention ? 0.18 : 0.12)
		case .cancelled, .idle:
			return .clear
		}
	}

	/// True only for unseen-attention waiting states — the one case where
	/// we still want a crisp stroke ring, because the user needs to
	/// notice that a backgrounded session is waiting on them.
	private var showsWaitingHalo: Bool {
		guard isUnseenAttention else { return false }
		switch effectiveStatusState {
		case .waitingForUser, .waitingForQuestion, .waitingForApproval:
			return true
		default:
			return false
		}
	}

	/// Foreground glyph inside the plate. Attention states (unseen
	/// completed / unseen failed) get a dedicated state glyph; everything
	/// else falls back to the row's identity glyph (chevron / arrow /
	/// anchor dot).
	@ViewBuilder
	private var plateGlyph: some View {
		let state = effectiveStatusState

		if isUnseenAttention && state == .completed {
			Image(systemName: "checkmark")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(Color.green)
				.accessibilityLabel("Completed in background")
		} else if isUnseenAttention && state == .failed {
			Image(systemName: "exclamationmark")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(Color.red)
				.accessibilityLabel("Failed in background")
		} else if threadDepth > 0 {
			// Sub-agent identity glyph.
			Image(systemName: "arrow.turn.down.right")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Color.secondary.opacity(0.55))
				.accessibilityHidden(true)
		} else if showsDisclosureChevron, let onToggleThreadCollapse {
			// Expandable root identity glyph — tappable disclosure affordance.
			// MCP-controlled roots tint the chevron orange when idle so the
			// row still signals "opened by an MCP client" without needing a
			// dedicated leading rail.
			let chevronColor: Color = {
				if isDisclosureHovered { return .accentColor }
				return isMCPControlledRoot ? Self.mcpAccentColor : .secondary
			}()
			Button {
				onToggleThreadCollapse()
			} label: {
				Image(systemName: "chevron.right")
					.font(.system(size: 11, weight: .semibold))
					.foregroundColor(chevronColor)
					.rotationEffect(.degrees(isThreadCollapsed ? 0 : 90))
					.animation(.easeInOut(duration: 0.15), value: isThreadCollapsed)
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isDisclosureHovered = $0 }
			.hoverTooltip(disclosureAccessibilityLabel)
			.accessibilityLabel(disclosureAccessibilityLabel)
		} else if isMCPControlledRoot {
			// MCP-controlled leaf root — keeps the existing anchor-dot
			// design but recolors it orange and bumps the size a hair so
			// it reads as a deliberate "this chat came from an MCP client"
			// marker instead of a generic idle dot.
			Circle()
				.fill(Self.mcpAccentColor.opacity((isHovered || isActive) ? 0.95 : 0.8))
				.frame(width: 5, height: 5)
				.accessibilityHidden(true)
		} else {
			// Leaf root anchor dot — reacts with hover/active to rhyme
			// with the row's outline highlight. While the row is running the
			// dot also adopts the running accent (blue / MCP-orange) at full
			// opacity so the spinner reads with contrast against the arc.
			let isRunningRow = runState == .running
			let dotColor: Color = isRunningRow
				? runningAccentColor
				: Color.secondary
			let dotOpacity: Double = {
				if isRunningRow { return 1.0 }
				return (isHovered || isActive) ? 0.55 : 0.22
			}()
			Circle()
				.fill(dotColor.opacity(dotOpacity))
				.frame(width: 3, height: 3)
				.accessibilityHidden(true)
		}
	}

	/// Tooltip for the plate. Expandable roots rely on their chevron
	/// button's own tooltip instead, so we return nil there to avoid
	/// two competing bubbles on the same region.
	private var plateTooltip: String? {
		if showsDisclosureChevron { return nil }

		let state = effectiveStatusState
		let stateTooltip: String?
		switch state {
		case .running:
			stateTooltip = "Running"
		case .waitingForUser, .waitingForQuestion, .waitingForApproval:
			stateTooltip = waitingTooltip(for: state, unseen: isUnseenAttention)
		case .completed:
			stateTooltip = isUnseenAttention
				? "Completed in background — select or dismiss to clear"
				: nil
		case .failed:
			stateTooltip = isUnseenAttention
				? "Failed in background — select or dismiss to clear"
				: "Last run failed"
		case .cancelled, .idle:
			stateTooltip = nil
		}

		switch (stateTooltip, isMCPControlledRoot) {
		case (let tip?, true):
			return tip + " — MCP Controlled"
		case (nil, true):
			return "MCP Controlled"
		case (let tip, false):
			return tip
		}
	}

	/// Accessibility companion to `plateTooltip`. Always returns a
	/// non-empty label for MCP-controlled roots so VoiceOver still
	/// announces the affordance after the rail was removed.
	private var plateAccessibilityLabel: String {
		if let tip = plateTooltip { return tip }
		return isMCPControlledRoot ? "MCP controlled" : ""
	}

	private func waitingTooltip(
		for state: AgentSessionRunState,
		unseen: Bool
	) -> String {
		let base: String
		switch state {
		case .waitingForApproval:
			base = "Waiting for approval"
		case .waitingForQuestion:
			base = "Waiting for your answer"
		default:
			base = "Waiting for your input"
		}
		return unseen ? base + " — select or dismiss to clear" : base
	}
}

struct AgentStashedSessionRow: View {
	let stashed: StashedTab
	let onRestore: () -> Void
	let onDelete: () -> Void

	@State private var isHovered = false
	@State private var isRestoreHovered = false
	@State private var isDeleteHovered = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	private var rowMinHeight: CGFloat { fontPreset.scaledClamped(30, min: 30, max: 40) }
	private var rowHorizontalPadding: CGFloat { fontPreset.scaledClamped(10, max: 14) }
	private var rowVerticalPadding: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var rowCornerRadius: CGFloat { fontPreset.scaledClamped(16, max: 20) }
	private var rowSpacing: CGFloat { fontPreset.scaledClamped(8, max: 11) }
	private var titlePinSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var titleVStackSpacing: CGFloat { fontPreset.scaledClamped(2, max: 3) }
	private var leadingIconSize: CGFloat { fontPreset.scaledClamped(12, max: 15) }
	private var pinIconSize: CGFloat { fontPreset.scaledClamped(10, max: 13) }

	var body: some View {
		HStack(spacing: rowSpacing) {
			Image(systemName: "tray.and.arrow.down")
				.font(.system(size: leadingIconSize))
				.foregroundStyle(.secondary)

			VStack(alignment: .leading, spacing: titleVStackSpacing) {
				HStack(spacing: titlePinSpacing) {
					Text(stashed.tab.name)
						.font(fontPreset.swiftUIFont(sizeAtNormal: 13))
						.lineLimit(1)
						.truncationMode(.tail)
					if stashed.tab.isPinned {
						Image(systemName: "pin.fill")
							.font(.system(size: pinIconSize))
							.foregroundStyle(.secondary)
					}
				}
			}

			Spacer()

			if isHovered {
				Button(action: onRestore) {
					Image(systemName: "tray.and.arrow.up")
						.font(.system(size: 11))
						.foregroundColor(isRestoreHovered ? .accentColor : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isRestoreHovered = $0 }
				.hoverTooltip("Restore tab")

				Button(action: onDelete) {
					Image(systemName: "trash")
						.font(.system(size: 11))
						.foregroundColor(isDeleteHovered ? .red : .secondary)
				}
				.buttonStyle(.plain)
				.onHover { isDeleteHovered = $0 }
				.hoverTooltip("Delete stashed tab")
			}
		}
		.padding(.horizontal, rowHorizontalPadding)
		.padding(.vertical, rowVerticalPadding)
		.frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
		.background(
			Group {
				if isHovered {
					RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
						.stroke(Color(NSColor.systemGray).opacity(0.4), lineWidth: 1)
				}
			}
		)
		.contentShape(Rectangle())
		.onHover { isHovered = $0 }
		.onTapGesture(perform: onRestore)
		.accessibilityLabel("\(stashed.tab.name), archived session")
	}
}

// MARK: - Agent Row Activity Arc

/// A compact, calm rotating arc used in place of the native `ProgressView`
/// inside the Agent Mode sidebar row's status slot.
///
/// Design goals:
/// - Match the 14pt status slot so titles stay aligned whether the row shows
///   a spinner, a waiting dot, a failed dot, or nothing at all.
/// - Rhyme with the circle-based waiting/failed dots (they all share the same
///   geometric vocabulary).
/// - Read as "actively processing" without competing with the green waiting
///   dot — running is informational, waiting is actionable, so running
///   should not out-shout it.
fileprivate struct AgentRowActivityArc: View {
	var tint: Color = .accentColor
	@State private var rotation: Double = 0

	var body: some View {
		Circle()
			.trim(from: 0.0, to: 0.7)
			.stroke(
				tint.opacity(0.75),
				style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
			)
			.frame(width: 15, height: 15)
			.rotationEffect(.degrees(rotation))
			.onAppear {
				withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
					rotation = 360
				}
			}
			.accessibilityLabel("Running")
	}
}

// MARK: - Agent Kind Extensions

extension DiscoverAgentKind {
	// displayName is defined in DiscoverAgentService.swift
	
	var iconName: String {
		switch self {
		case .codexExec: return "terminal"
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: return "cpu"
		case .gemini: return "sparkles"
		case .openCode: return "curlybraces.square"
		case .cursor: return "cursorarrow"
		}
	}
}
