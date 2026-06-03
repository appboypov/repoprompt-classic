//
//  ComposeTabBar.swift
//  RepoPrompt
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Represents the type of background activity for a compose tab
enum TabBusyType: Equatable {
	case none
	case discover        // Context Builder running (blue)
	case planGeneration  // Plan generation running (purple)
	case chatStreaming   // Chat response streaming (green)

	var tintColor: Color {
		switch self {
		case .none: return .secondary
		case .discover: return .blue
		case .planGeneration: return .purple
		case .chatStreaming: return .green
		}
	}
	
	var label: String {
		switch self {
		case .none: return ""
		case .discover: return "Context Builder running"
		case .planGeneration: return "Plan generation running"
		case .chatStreaming: return "Chat streaming"
		}
	}

	var isActive: Bool {
		self != .none
	}
}

struct ComposeTabBar: View {
	@ObservedObject var promptVM: PromptViewModel
	@ObservedObject var discoverVM: DiscoverAgentViewModel
	let chatBusyTabs: Set<UUID>
	@State private var hoveredTabID: UUID?
	@State private var hoveredCloseButtonID: UUID?
	@State private var tabBeingRenamed: ComposeTabState?
	@State private var renameText: String = ""
	@State private var isShowingRenameAlert: Bool = false
	@State private var isShowingAllTabsPopover: Bool = false
	@State private var hasRenderedInitialLayout = false
	
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private var tabs: [ComposeTabState] { promptVM.currentComposeTabs }
	private var activeID: UUID? { promptVM.activeComposeTabID }
	private var canAddMoreTabs: Bool { promptVM.composeTabCount < promptVM.composeTabLimit }
	
	private var tabBarHeight: CGFloat { fontPreset.scaledClamped(40, min: 40, max: 48) }
	private var controlButtonSize: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 34) }
	private var controlIconSize: CGFloat { fontPreset.scaledClamped(11, min: 11, max: 14) }
	private var horizontalPadding: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 22) }
	
	var body: some View {
		GeometryReader { geometry in
			// Constants used in both passes
			let containerHPad = LayoutMetrics.tabContainerHorizontalPadding(for: fontPreset)
			let minBudget: CGFloat = 100

			// determineVisibleTabs handles overflow buttons internally, so only subtract + button, all-tabs button and gaps
			let budget = max(
				minBudget,
				geometry.size.width - LayoutMetrics.plusButtonWidth(for: fontPreset) - LayoutMetrics.allTabsButtonWidth(for: fontPreset) - (LayoutMetrics.containerToControlSpacing(for: fontPreset) * 2) - containerHPad - LayoutMetrics.controlEdgePadding(for: fontPreset)
			)
			let layout = determineVisibleTabs(
				tabs: tabs,
				activeID: activeID,
				availableWidth: budget
			)

			// Use HStack layout so elements naturally position next to each other
			return HStack(spacing: LayoutMetrics.containerToControlSpacing(for: fontPreset)) {
				// Leading overflow button
				if !layout.hiddenLeading.isEmpty {
					overflowMenu(tabs: layout.hiddenLeading, direction: "Leading")
				}

				// Core cluster (tabs only)
				HStack(spacing: 0) {
					AccordionTabLayout(
						panes: layout.visibleTabs,
						activeID: activeID,
						availableWidth: layout.availableWidth,
						spacing: 0,
						content: { pane, width in
					let tab = pane.state
					let index = pane.globalIndex
					let isActive = (tab.id == activeID)
					let isHovered = hoveredTabID == tab.id
					let busyType: TabBusyType = {
						if discoverVM.tabsWithActiveDiscoverRun.contains(tab.id) {
							return .discover
						} else if discoverVM.tabsWithActivePlanGeneration.contains(tab.id) {
							return .planGeneration
						} else if chatBusyTabs.contains(tab.id) {
							return .chatStreaming
						}
						return .none
					}()
					let canClose = promptVM.composeTabCount > 1
					let isRestoring = isActive && promptVM.isSwitchingComposeTab

					ComposeTabItemView(
						fontPreset: fontPreset,
						tab: tab,
						tabIndex: index,
						isActive: isActive,
						isHovered: isHovered,
						isCloseButtonHovered: hoveredCloseButtonID == tab.id,
						isDirty: promptVM.isTabDirty(tab),
						busyType: busyType,
						canClose: canClose,
						maxWidth: width,
						isRestoring: isRestoring,
						onClose: {
							guard canClose else { return }
							Task { await promptVM.stashTab(tab.id) }
						},
						onCloseHover: { hovering in
									hoveredCloseButtonID = hovering ? tab.id : nil
								}
					)
						.frame(width: width)
						.contextMenu {
							Button("Duplicate") {
								Task {
									await promptVM.createDuplicateComposeTab(named: "\(tab.name) Copy")
									}
								}
								Button("Rename…") {
									tabBeingRenamed = tab
									renameText = tab.name
									isShowingRenameAlert = true
								}
								Button("Copy Tab ID") {
									NSPasteboard.general.clearContents()
									NSPasteboard.general.setString(tab.id.uuidString, forType: .string)
								}
								Button("Save Tab as Preset…") {
									Task { await promptVM.saveCurrentTabAsPreset(tab.id) }
								}
								Button("Stash Tab for Later") {
									Task { await promptVM.stashTab(tab.id) }
								}
								.disabled(tabs.count <= 1)
								Divider()
								Button("Delete Tab") {
									Task { await promptVM.closeComposeTab(tab.id) }
								}
								Button("Close Tabs to the Left") {
									Task { await promptVM.closeTabsToLeft(of: tab.id) }
								}
								.disabled(index == 0)
								Button("Close Tabs to the Right") {
									Task { await promptVM.closeTabsToRight(of: tab.id) }
								}
								.disabled(index == tabs.count - 1)
							}
						.onTapGesture {
							guard tab.id != activeID else { return }
							Task { await promptVM.switchComposeTab(tab.id) }
						}
							.onHover { hovering in
								hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
							}
							.onDrag {
								NSItemProvider(object: NSString(string: tab.id.uuidString))
							}
							.onDrop(
								of: [UTType.text],
								delegate: ComposeTabReorderDelegate(targetIndex: index, promptVM: promptVM)
							)

							// Divider after each visible tab except the last visible one
							if pane.state.id != layout.visibleTabs.last?.state.id {
								Divider()
									.frame(height: fontPreset.scaledClamped(20, min: 20, max: 26))
									.padding(.horizontal, fontPreset.scaledClamped(4, min: 4, max: 5))
							}
						}
					)
					.padding(.leading, LayoutMetrics.clusterPaddingLeading(for: fontPreset))
					.padding(.trailing, LayoutMetrics.clusterPaddingTrailing(for: fontPreset))
					.padding(.vertical, fontPreset.scaledClamped(4, min: 4, max: 5))
					.background(
						RoundedRectangle(cornerRadius: 20)
							.fill(Color.primary.opacity(0.08))
					)
				}

				// Trailing ellipsis (if needed)
				if !layout.hiddenTrailing.isEmpty {
					overflowMenu(tabs: layout.hiddenTrailing, direction: "Trailing")
				}

				// View all tabs button
				allTabsButton

				// Trailing '+' button (always far right)
				newTabMenu
			}
			.padding(.trailing, LayoutMetrics.controlEdgePadding(for: fontPreset))
			// Animate identity and active changes only (not width) to avoid stale sizing
			.animation(hasRenderedInitialLayout ? .easeInOut(duration: 0.16) : nil, value: layout.visibleTabs.map { $0.state.id })
			.animation(hasRenderedInitialLayout ? .easeInOut(duration: 0.16) : nil, value: activeID)
		}
		.frame(height: tabBarHeight)
		.padding(.horizontal, horizontalPadding)
		.onAppear {
			guard !hasRenderedInitialLayout else { return }
			DispatchQueue.main.async {
				hasRenderedInitialLayout = true
			}
		}
		.alert("Rename Tab", isPresented: $isShowingRenameAlert, presenting: tabBeingRenamed) { _ in
			TextField("Tab name", text: $renameText)
				.onSubmit {
					submitRename()
				}
			Button("Save") {
				submitRename()
			}
			Button("Cancel", role: .cancel) {
				resetRenameState()
			}
		} message: { _ in
			Text("Enter a new name for this compose tab.")
		}
	}
	
	private var newTabMenu: some View {
		Menu {
			Button("Duplicate Current Tab") {
				Task { await promptVM.createDuplicateComposeTab() }
			}
			Button("New Blank Tab (⌘T)") {
				Task { await promptVM.createBlankComposeTab() }
			}
			let presets = promptVM.availablePresetsForComposeTabs
			if !presets.isEmpty {
				Menu("New Tab from Preset") {
					ForEach(presets) { preset in
						Button(preset.name) {
							Task { await promptVM.createComposeTab(from: preset) }
						}
					}
				}
			}
		} label: {
			Image(systemName: "plus")
		}
		.menuIndicator(.hidden)
		.buttonStyle(RoundedBorderButtonStyle(size: controlButtonSize, iconSize: controlIconSize))
		// Auto-stash will make room if at the tab limit
		.hoverTooltip("New Tab")
	}
	
	private var allTabsButton: some View {
		Button {
			isShowingAllTabsPopover.toggle()
		} label: {
			Image(systemName: "square.grid.2x2")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
		}
		.buttonStyle(RoundedBorderButtonStyle(size: 28, iconSize: 11))
		.hoverTooltip("View All Tabs")
		.popover(isPresented: $isShowingAllTabsPopover, arrowEdge: .bottom) {
			AllTabsPopoverView(
				promptVM: promptVM,
				discoverVM: discoverVM,
				chatBusyTabs: chatBusyTabs,
				isPresented: $isShowingAllTabsPopover
			)
		}
	}
	
	/// Creates an overflow menu for hidden tabs
	private func overflowMenu(tabs: [ComposeTabState], direction: String) -> some View {
		Menu {
			ForEach(tabs) { tab in
				let busyType: TabBusyType = {
					if discoverVM.tabsWithActiveDiscoverRun.contains(tab.id) {
						return .discover
					} else if discoverVM.tabsWithActivePlanGeneration.contains(tab.id) {
						return .planGeneration
					} else if chatBusyTabs.contains(tab.id) {
						return .chatStreaming
					}
					return .none
				}()
				Button {
					guard tab.id != promptVM.activeComposeTabID else { return }
					Task { await promptVM.switchComposeTab(tab.id) }
				} label: {
					HStack {
						if busyType.isActive {
							ProgressView()
								.scaleEffect(0.5)
								.tint(busyType.tintColor)
						}
						Text(tab.name)
					}
				}
			}
		} label: {
			Image(systemName: "ellipsis")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
		}
		.menuIndicator(.hidden)
		.buttonStyle(RoundedBorderButtonStyle(size: 28, iconSize: 11))
		.hoverTooltip("\(direction) Hidden Tabs")
	}
}

private struct ComposeTabItemView: View {
	let fontPreset: FontScalePreset
	let tab: ComposeTabState
	let tabIndex: Int
	let isActive: Bool
	let isHovered: Bool
	let isCloseButtonHovered: Bool
	let isDirty: Bool
	let busyType: TabBusyType
	let canClose: Bool
	let maxWidth: CGFloat
	let isRestoring: Bool
	let onClose: () -> Void
	let onCloseHover: (Bool) -> Void

	private var keyboardShortcut: String? {
		guard tabIndex < 9 else { return nil }
		return "⌘\(tabIndex + 1)"
	}

	var body: some View {
		HStack(spacing: fontPreset.scaledClamped(6, min: 6, max: 8)) {
			if isRestoring || busyType.isActive {
				ProgressView()
					.scaleEffect(fontPreset.scaledClamped(0.6, min: 0.6, max: 0.72))
					.frame(width: fontPreset.scaledClamped(12, min: 12, max: 16), height: fontPreset.scaledClamped(12, min: 12, max: 16))
					.tint(isRestoring ? .secondary : busyType.tintColor)
					.opacity(0.9)
					.help(isRestoring ? "Restoring tab" : busyType.label)
			}

			Text(tab.name)
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: isActive ? .semibold : .medium))
				.foregroundColor(isActive ? .primary : .secondary)
				.lineLimit(1)
				.truncationMode(.tail)

			// Only show shortcut if we have enough space
			if let shortcut = keyboardShortcut, maxWidth > 120 {
				Text(shortcut)
					.font(.system(size: 11, weight: .medium))
					.foregroundColor(.secondary)
					.opacity(0.5)
			}

			Spacer(minLength: 4)

			// Close button - only rendered when hovered so text can use that space otherwise
			if canClose && maxWidth > 100 && isHovered {
				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
						.foregroundColor(.primary)
						.frame(width: fontPreset.scaledClamped(16, min: 16, max: 20), height: fontPreset.scaledClamped(16, min: 16, max: 20))
						.background(
							Circle()
								.fill(isCloseButtonHovered ? Color.primary.opacity(0.15) : Color.clear)
						)
				}
				.buttonStyle(.plain)
				.onHover { hovering in
					onCloseHover(hovering)
				}
				.hoverTooltip("Stash Tab")
			}
		}
		.frame(minHeight: fontPreset.scaledClamped(16, min: 16, max: 22)) // Prevent height shift when button appears/disappears
		.padding(.horizontal, fontPreset.scaledClamped(12, min: 12, max: 16))
		.padding(.vertical, fontPreset.scaledClamped(6, min: 6, max: 8))
		.background(
			Group {
				if isActive {
					RoundedRectangle(cornerRadius: 16)
						.fill(Color.primary.opacity(0.2))
						.shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
				} else if isHovered {
					RoundedRectangle(cornerRadius: 16)
						.fill(Color.primary.opacity(0.08))
				}
			}
		)
		.overlay(
			Group {
				if isActive {
					RoundedRectangle(cornerRadius: 16)
						.strokeBorder(
							Color.primary.opacity(isHovered ? 0.5 : 0.3),
							lineWidth: 0.5
						)
				}
			}
		)
		.zIndex(isActive ? 1 : 0)
		.contentShape(Rectangle())
		// Keep: show the full tab name on hover (works even when text truncates)
		.hoverTooltip(tab.name)
	}
}

private struct ComposeTabReorderDelegate: DropDelegate {
	let targetIndex: Int
	let promptVM: PromptViewModel
	
	func validateDrop(info: DropInfo) -> Bool {
		info.hasItemsConforming(to: [UTType.text])
	}
	
	func performDrop(info: DropInfo) -> Bool {
		guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
		provider.loadObject(ofClass: NSString.self) { value, _ in
			Task { @MainActor in
				guard
					let string = value as? String,
					let id = UUID(uuidString: string),
					let fromIndex = promptVM.currentComposeTabs.firstIndex(where: { $0.id == id })
				else { return }

				await promptVM.moveComposeTab(from: fromIndex, to: targetIndex)
			}
		}
		return true
	}
}

// MARK: - Tab Visibility & Layout Models

/// Layout constants shared between visibility calculation and accordion layout
private enum LayoutMetrics {
	static func idealTabWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(180, min: 180, max: 240) }
	static func minTabWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(80, min: 80, max: 104) }
	static func activeTabMinWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(120, min: 120, max: 160) }
	
	// Controls
	static func overflowButtonWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(28, min: 28, max: 34) }
	static func overflowButtonSpacing(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(4, min: 4, max: 6) }
	static func plusButtonWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(28, min: 28, max: 34) }
	static func allTabsButtonWidth(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(28, min: 28, max: 34) }
	static func containerToControlSpacing(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(4, min: 4, max: 6) } // Gap between rounded rect and trailing controls
	static func controlEdgePadding(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(4, min: 4, max: 6) } // Padding from screen edge for trailing controls
	
	// Inner paddings for the rounded tab cluster background
	static func clusterPaddingLeading(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(6, min: 6, max: 8) }
	static func clusterPaddingTrailing(for preset: FontScalePreset) -> CGFloat { preset.scaledClamped(6, min: 6, max: 8) }
	
	// Visual separators/padding actually present in the view hierarchy
	// Sum of inner paddings (leading + trailing) used in budgeting passes
	static func tabContainerHorizontalPadding(for preset: FontScalePreset) -> CGFloat { clusterPaddingLeading(for: preset) + clusterPaddingTrailing(for: preset) }
	
	static let separatorWidth: CGFloat = 9 // divider ~1pt + 4pt each side padding = ~9pt
}

/// Represents a tab pane with its global index for reordering/switching
private struct TabPane {
	let state: ComposeTabState
	let globalIndex: Int
}

/// Result of visibility calculation showing which tabs to render
private struct TabVisibilityLayout {
	let visibleTabs: [TabPane]
	let hiddenLeading: [ComposeTabState]
	let hiddenTrailing: [ComposeTabState]
	let availableWidth: CGFloat
}

// MARK: - Accordion Tab Layout
/// Custom layout that fills available width and compresses tabs in an accordion style
/// when space is limited. Tabs farther from the active tab compress more.
private struct AccordionTabLayout<Content: View>: View {
	let panes: [TabPane]
	let activeID: UUID?
	let availableWidth: CGFloat
	let spacing: CGFloat
	@ViewBuilder let content: (TabPane, CGFloat) -> Content

	var body: some View {
		let widths = computeWidths()
		HStack(spacing: 0) {
			ForEach(Array(panes.enumerated()), id: \.element.state.id) { index, pane in
				content(pane, widths[safe: index] ?? LayoutMetrics.minTabWidth(for: FontScalePreset.current))
			}
		}
	}

	private func computeWidths() -> [CGFloat] {
		guard !panes.isEmpty else { return [] }

		let tabCount = panes.count
		let activeIndex = panes.firstIndex(where: { $0.state.id == activeID }) ?? 0

		// Tabs-only width budget (AccordionTabLayout is called with spacing = 0 in this file)
		let totalSpacing = spacing * CGFloat(tabCount - 1)
		let availableForTabs = max(0, availableWidth - totalSpacing)

		// Weighting: active tab gets weight 1.0, others scale linearly down to 0.5 at farthest distance
		let maxDistance = max(activeIndex, tabCount - 1 - activeIndex)
		func weight(for index: Int) -> CGFloat {
			if index == activeIndex { return 1.0 }
			guard maxDistance > 0 else { return 1.0 }
			let norm = CGFloat(abs(index - activeIndex)) / CGFloat(maxDistance)
			return 1.0 - (norm * 0.5) // [0.5, 1.0]
		}
		let weights: [CGFloat] = (0..<tabCount).map { weight(for: $0) }
		let totalWeight = max(0.0001, weights.reduce(0, +))

		// Minimum widths per tab
		let mins: [CGFloat] = (0..<tabCount).map { idx in
			idx == activeIndex ? LayoutMetrics.activeTabMinWidth(for: FontScalePreset.current) : LayoutMetrics.minTabWidth(for: FontScalePreset.current)
		}
		let minSum = mins.reduce(0, +)

		// Guard: if minima exceed budget (shouldn't happen due to determineVisibleTabs), clamp equally
		if minSum >= availableForTabs {
			// Distribute the budget proportionally to minima to ensure exact fit
			let scale = availableForTabs / max(0.0001, minSum)
			let scaled = mins.map { $0 * scale }
			return pixelAccurateWidths(target: availableForTabs, proposed: scaled)
		}

		// Initial target widths from weights
		var widths = (0..<tabCount).map { i in
			max(mins[i], availableForTabs * (weights[i] / totalWeight))
		}

		// If we overflow, shrink proportionally from tabs that are above their minima
		var sum = widths.reduce(0, +)
		if sum > availableForTabs {
			let overflow = sum - availableForTabs
			var slacks = widths.enumerated().map { idx, w in w - mins[idx] }
			let totalSlack = slacks.reduce(0, +)
			if totalSlack > 0 {
				// Reduce each width by its share of the overflow
				for i in 0..<tabCount {
					let reduce = overflow * (slacks[i] / totalSlack)
					widths[i] = max(mins[i], widths[i] - reduce)
				}
			} else {
				// No slack (should not happen), clamp all to minima
				widths = mins
			}
		} else if sum < availableForTabs {
			// If we underflow, add proportionally by weights above minima
			let under = availableForTabs - sum
			// Compute "growth weights" where tabs at minima still participate
			let growthWeights = weights
			let totalGrowth = max(0.0001, growthWeights.reduce(0, +))
			for i in 0..<tabCount {
				widths[i] += under * (growthWeights[i] / totalGrowth)
			}
		}

		// Second pass: if the active tab's title would be truncated, rebalance
		// some width from other tabs toward the active tab.
		widths = adaptActiveWidth(widths: widths, mins: mins, activeIndex: activeIndex)

		// Ensure pixel-accurate sum to exactly match availableForTabs
		return pixelAccurateWidths(target: availableForTabs, proposed: widths)
	}

	private func idealTitleWidth(for pane: TabPane, isActiveTab: Bool) -> CGFloat {
		let name = pane.state.name
		if name.isEmpty {
			return isActiveTab ? LayoutMetrics.activeTabMinWidth(for: FontScalePreset.current) : LayoutMetrics.minTabWidth(for: FontScalePreset.current)
		}

		let preset = FontScalePreset.current
		let font = preset.nsFont(sizeAtNormal: 12, weight: isActiveTab ? .semibold : .medium)

		let attributes: [NSAttributedString.Key: Any] = [.font: font]
		let textWidth = (name as NSString).size(withAttributes: attributes).width

		// ComposeTabItemView uses horizontal padding and space for shortcut, spinner and close button.
		let baseHorizontalPadding: CGFloat = preset.scaledClamped(12, min: 12, max: 16) * 2        // .padding(.horizontal)
		let accessoryAllowance: CGFloat = preset.scaledClamped(32, min: 32, max: 42)               // approximate extra for shortcut/spinner/close

		let rawWidth = textWidth + baseHorizontalPadding + accessoryAllowance
		let minWidth = isActiveTab ? LayoutMetrics.activeTabMinWidth(for: preset) : LayoutMetrics.minTabWidth(for: preset)

		return min(max(rawWidth, minWidth), LayoutMetrics.idealTabWidth(for: preset))
	}

	private func adaptActiveWidth(widths: [CGFloat], mins: [CGFloat], activeIndex: Int) -> [CGFloat] {
		guard activeIndex >= 0, activeIndex < widths.count else { return widths }

		var adjusted = widths

		let activePane = panes[activeIndex]
		let idealActiveWidth = idealTitleWidth(for: activePane, isActiveTab: true)
		let currentActiveWidth = adjusted[activeIndex]

		// Only rebalance if the active tab is narrower than its ideal title width
		// (i.e. the title would be truncated at the current width).
		guard idealActiveWidth > currentActiveWidth else { return adjusted }

		let needed = idealActiveWidth - currentActiveWidth
		var totalStealable: CGFloat = 0
		var stealable = [CGFloat](repeating: 0, count: adjusted.count)

		// Compute how much width we can steal from non-active tabs without
		// shrinking them below their own minimum widths.
		for i in 0..<adjusted.count where i != activeIndex {
			let maxShrink = max(0, adjusted[i] - mins[i])
			if maxShrink > 0 {
				totalStealable += maxShrink
				stealable[i] = maxShrink
			}
		}

		guard totalStealable > 0 else { return adjusted }

		let delta = min(needed, totalStealable)

		for i in 0..<adjusted.count where i != activeIndex && stealable[i] > 0 {
			let share = stealable[i] / totalStealable
			let shrink = delta * share
			adjusted[i] -= shrink
			adjusted[activeIndex] += shrink
		}

		return adjusted
	}

	// Convert widths to pixel grid while preserving exact total budget
	private func pixelAccurateWidths(target: CGFloat, proposed: [CGFloat]) -> [CGFloat] {
		let scale = NSScreen.main?.backingScaleFactor ?? 2.0

		let targetPx = Int((target * scale).rounded(.toNearestOrEven))
		let floatsPx = proposed.map { $0 * scale }

		// Start with floor allocations to avoid overshoot
		var baseInts = floatsPx.map { Int(floor($0)) }
		var remainder = targetPx - baseInts.reduce(0, +)

		if remainder > 0 {
			// Distribute remaining pixels to the largest fractional parts
			let fracs = floatsPx.enumerated().map { (idx, v) in (idx, v - floor(v)) }
			let order = fracs.sorted { a, b in a.1 > b.1 }.map { $0.0 }
			var i = 0
			while remainder > 0 && i < order.count {
				baseInts[order[i]] += 1
				remainder -= 1
				i += 1
			}
		} else if remainder < 0 {
			// Remove pixels from the smallest fractional parts (closest to integer)
			let fracs = floatsPx.enumerated().map { (idx, v) in (idx, v - floor(v)) }
			let order = fracs.sorted { a, b in a.1 < b.1 }.map { $0.0 }
			var i = 0
			while remainder < 0 && i < order.count {
				if baseInts[order[i]] > 0 {
					baseInts[order[i]] -= 1
					remainder += 1
				}
				i += 1
			}
		}

		// Convert back to points
		return baseInts.map { CGFloat($0) / scale }
	}
}

private extension ComposeTabBar {
	/// Determines which tabs to show based on available width, prioritizing the active tab and nearby tabs
	func determineVisibleTabs(
		tabs: [ComposeTabState],
		activeID: UUID?,
		availableWidth: CGFloat // This is cluster budget excluding "+" and container padding
	) -> TabVisibilityLayout {
		guard !tabs.isEmpty else {
			return TabVisibilityLayout(
				visibleTabs: [],
				hiddenLeading: [],
				hiddenTrailing: [],
				availableWidth: 0
			)
		}
		
		let activeIndex = tabs.firstIndex(where: { $0.id == activeID }) ?? 0
		
		var remainingWidth = max(0, availableWidth)
		
		// Track hidden sides to reserve overflow buttons (once)
		var hasHiddenLeading = false
		var hasHiddenTrailing = false
		
		// Always include the active tab first
		var visibleIndices = Set<Int>([activeIndex])
		
		// The "allocatedWidth" tracks tabs + separators for what we plan to render
		var allocatedWidth: CGFloat = LayoutMetrics.activeTabMinWidth(for: fontPreset)
		
		var leftOffset = 1
		var rightOffset = 1
		var addingLeft = true
		
		// Helper to try adding a tab and update allocations (min width; the accordion will distribute later)
		func tryAddTab(at index: Int, isLeftSide: Bool) -> Bool {
			let candidateWidth = LayoutMetrics.minTabWidth(for: fontPreset)
			let spaceNeeded = candidateWidth + LayoutMetrics.separatorWidth
			
			// If not enough room, reserve overflow for that side (once) and retry once
			if allocatedWidth + spaceNeeded >= remainingWidth {
				if isLeftSide, index >= 0, !hasHiddenLeading {
					hasHiddenLeading = true
					remainingWidth -= (LayoutMetrics.overflowButtonWidth(for: fontPreset) + LayoutMetrics.overflowButtonSpacing(for: fontPreset))
					// Retry after reservation
					if allocatedWidth + spaceNeeded >= remainingWidth {
						return false
					}
				} else if !isLeftSide, index < tabs.count, !hasHiddenTrailing {
					hasHiddenTrailing = true
					remainingWidth -= (LayoutMetrics.overflowButtonWidth(for: fontPreset) + LayoutMetrics.overflowButtonSpacing(for: fontPreset))
					// Retry after reservation
					if allocatedWidth + spaceNeeded >= remainingWidth {
						return false
					}
				} else {
					return false
				}
			}
			
			visibleIndices.insert(index)
			allocatedWidth += spaceNeeded
			return true
		}
		
		while allocatedWidth < remainingWidth {
			let leftIndex = activeIndex - leftOffset
			let rightIndex = activeIndex + rightOffset
			
			var addedOne = false
			
			if addingLeft, leftIndex >= 0, !visibleIndices.contains(leftIndex) {
				addedOne = tryAddTab(at: leftIndex, isLeftSide: true)
				leftOffset += 1
			} else if !addingLeft, rightIndex < tabs.count, !visibleIndices.contains(rightIndex) {
				addedOne = tryAddTab(at: rightIndex, isLeftSide: false)
				rightOffset += 1
			} else if leftIndex >= 0, !visibleIndices.contains(leftIndex) {
				addedOne = tryAddTab(at: leftIndex, isLeftSide: true)
				leftOffset += 1
			} else if rightIndex < tabs.count, !visibleIndices.contains(rightIndex) {
				addedOne = tryAddTab(at: rightIndex, isLeftSide: false)
				rightOffset += 1
			} else {
				break
			}
			
			if !addedOne {
				// Couldn't add further on this side; stop expansion.
				break
			}
			addingLeft.toggle()
		}

		// After the loop: ensure we've reserved space for any overflow buttons needed
		// This handles the case where we broke from the loop after hitting one side's limit
		// but there are still hidden tabs on the other side that weren't attempted
		let minVisibleIndex = visibleIndices.min() ?? 0
		let maxVisibleIndex = visibleIndices.max() ?? (tabs.count - 1)

		// Check if there are hidden tabs on the left that need an overflow button
		if minVisibleIndex > 0 && !hasHiddenLeading {
			hasHiddenLeading = true
			remainingWidth -= (LayoutMetrics.overflowButtonWidth(for: fontPreset) + LayoutMetrics.overflowButtonSpacing(for: fontPreset))
		}

		// Check if there are hidden tabs on the right that need an overflow button
		if maxVisibleIndex < tabs.count - 1 && !hasHiddenTrailing {
			hasHiddenTrailing = true
			remainingWidth -= (LayoutMetrics.overflowButtonWidth(for: fontPreset) + LayoutMetrics.overflowButtonSpacing(for: fontPreset))
		}

		// Finalize lists
		var visibleTabs: [TabPane] = []
		var hiddenLeading: [ComposeTabState] = []
		var hiddenTrailing: [ComposeTabState] = []
		
		for (index, tab) in tabs.enumerated() {
			if visibleIndices.contains(index) {
				visibleTabs.append(TabPane(state: tab, globalIndex: index))
			} else if index < activeIndex {
				hiddenLeading.append(tab)
			} else {
				hiddenTrailing.append(tab)
			}
		}
		
		visibleTabs.sort { $0.globalIndex < $1.globalIndex }
		
		// Important: return tabs-only width (subtract separator widths). The Accordion fills this width,
		// and our actual separators are drawn outside it.
		let separatorCount = max(0, visibleTabs.count - 1)
		let tabsOnlyWidth = max(0, remainingWidth - (CGFloat(separatorCount) * LayoutMetrics.separatorWidth))
		
		return TabVisibilityLayout(
			visibleTabs: visibleTabs,
			hiddenLeading: hiddenLeading,
			hiddenTrailing: hiddenTrailing,
			availableWidth: tabsOnlyWidth
		)
	}
	
	func submitRename() {
		let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
		if let tab = tabBeingRenamed, !trimmed.isEmpty {
			promptVM.renameComposeTab(tab.id, to: trimmed)
		}
		resetRenameState()
	}
	
	func resetRenameState() {
		isShowingRenameAlert = false
		tabBeingRenamed = nil
		renameText = ""
	}
}

// MARK: - All Tabs Popover

private struct AllTabsPopoverView: View {
	@ObservedObject var promptVM: PromptViewModel
	@ObservedObject var discoverVM: DiscoverAgentViewModel
	let chatBusyTabs: Set<UUID>
	@Binding var isPresented: Bool
	@State private var hoveredTabID: UUID?
	@State private var hoveredStashedID: UUID?

	private var openTabCountLabel: String {
		let count = promptVM.composeTabCount
		let limit = promptVM.composeTabLimit
		if count > limit {
			return "\(count) open • UI cap \(limit)"
		}
		return "\(count)/\(limit)"
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header
			HStack {
				Text("All Tabs")
					.font(.headline)
				Spacer()
				Text(openTabCountLabel)
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 6)
			
			HStack {
				Button {
					Task {
						await promptVM.stashAllComposeTabs()
						isPresented = false
					}
				} label: {
					Label("Stash All Tabs", systemImage: "tray.and.arrow.down")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(promptVM.composeTabCount > 0 ? .secondary : .tertiary)
						.padding(.horizontal, 10)
						.padding(.vertical, 6)
						.background(
							RoundedRectangle(cornerRadius: 10, style: .continuous)
								.fill(Color.primary.opacity(0.06))
						)
				}
				.buttonStyle(.plain)
				.disabled(promptVM.composeTabCount == 0)
				.hoverTooltip("Stash all open tabs")
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.bottom, 8)
			
			Divider()
			
			ScrollView {
				let busyTabs = promptVM.currentComposeTabs.filter { tab in
					discoverVM.tabsWithActiveDiscoverRun.contains(tab.id) ||
					discoverVM.tabsWithActivePlanGeneration.contains(tab.id) ||
					chatBusyTabs.contains(tab.id)
				}.sorted { $0.lastModified > $1.lastModified }
				let nonBusyTabs = promptVM.currentComposeTabs.filter { tab in
					!discoverVM.tabsWithActiveDiscoverRun.contains(tab.id) &&
					!discoverVM.tabsWithActivePlanGeneration.contains(tab.id) &&
					!chatBusyTabs.contains(tab.id)
				}.sorted { $0.lastModified > $1.lastModified }
				
				VStack(alignment: .leading, spacing: 4) {
					// In Progress section
					if !busyTabs.isEmpty {
						HStack {
							Text("In Progress")
								.font(.subheadline)
								.foregroundColor(.secondary)
							Spacer()
							Text("\(busyTabs.count)")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						.padding(.horizontal, 8)
						.padding(.bottom, 4)
						
						ForEach(busyTabs) { tab in
							tabRow(tab: tab)
						}
						
						if !nonBusyTabs.isEmpty {
							Divider()
								.padding(.vertical, 8)
						}
					}
					
					// Other tabs section
					ForEach(nonBusyTabs) { tab in
						tabRow(tab: tab)
					}
					
					// Stashed tabs section
					if !promptVM.currentStashedTabs.isEmpty {
						Divider()
							.padding(.vertical, 8)
						
						HStack {
							Image(systemName: "tray.and.arrow.down")
								.foregroundColor(.secondary)
							Text("Stashed Tabs")
								.font(.subheadline)
								.foregroundColor(.secondary)
							Spacer()
						Button("Clear All") {
							Task { await promptVM.clearStashedTabs() }
						}
							.buttonStyle(.plain)
							.foregroundColor(.red)
							.hoverTooltip("Clear all stashed tabs")
							Text("\(promptVM.currentStashedTabs.count)")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						.padding(.horizontal, 8)
						.padding(.bottom, 4)
						
						ForEach(promptVM.currentStashedTabs.sorted { $0.stashedAt > $1.stashedAt }) { stashed in
							stashedTabRow(stashed: stashed)
						}
					}
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 8)
			}
			.frame(maxHeight: 300)
		}
		.frame(width: 280)
	}
	
	private func tabRow(tab: ComposeTabState) -> some View {
		let isActive = tab.id == promptVM.activeComposeTabID
		let isHovered = hoveredTabID == tab.id
		let busyType: TabBusyType = {
			if discoverVM.tabsWithActiveDiscoverRun.contains(tab.id) {
				return .discover
			} else if discoverVM.tabsWithActivePlanGeneration.contains(tab.id) {
				return .planGeneration
			} else if chatBusyTabs.contains(tab.id) {
				return .chatStreaming
			}
			return .none
		}()

		return HStack(spacing: 8) {
			// Busy indicator (first)
			if busyType.isActive {
				ProgressView()
					.scaleEffect(0.5)
					.frame(width: 10, height: 10)
					.tint(busyType.tintColor)
					.opacity(0.9)
			}
			
			// Tab name
			Text(tab.name)
				.font(.system(size: 12, weight: isActive ? .semibold : .regular))
				.foregroundColor(isActive ? .primary : .secondary)
				.lineLimit(1)
			
			Spacer()
			
			// Active indicator
			if isActive {
				Image(systemName: "checkmark")
					.font(.system(size: 10, weight: .semibold))
					.foregroundColor(.accentColor)
			}
			
			// Stash button (only on hover, not for active if it's the only tab)
			if isHovered && promptVM.composeTabCount > 1 {
				Button {
					Task {
						await promptVM.stashTab(tab.id)
					}
				} label: {
					Image(systemName: "tray.and.arrow.down")
						.font(.system(size: 10))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Stash for later")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(isActive ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
		)
		.contentShape(Rectangle())
		.onTapGesture {
			guard !isActive else { return }
			Task {
				await promptVM.switchComposeTab(tab.id)
				isPresented = false
			}
		}
		.onHover { hovering in
			hoveredTabID = hovering ? tab.id : nil
		}
	}
	
	private func stashedTabRow(stashed: StashedTab) -> some View {
		let isHovered = hoveredStashedID == stashed.id
		
		return HStack(spacing: 8) {
			// Tab name
			Text(stashed.tab.name)
				.font(.system(size: 12))
				.foregroundColor(.secondary)
				.lineLimit(1)
			
			Spacer()
			
			// Time since stashed
			Text(stashed.stashedAt.relativeTimeString())
				.font(.system(size: 10))
				.foregroundColor(.secondary.opacity(0.7))
			
			// Action buttons on hover
			if isHovered {
				Button {
					Task {
						await promptVM.unstashTab(stashed.id)
						isPresented = false
					}
				} label: {
					Image(systemName: "tray.and.arrow.up")
						.font(.system(size: 10))
						.foregroundColor(.accentColor)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Restore tab")
				
				Button {
					Task { await promptVM.deleteStashedTab(stashed.id) }
				} label: {
					Image(systemName: "trash")
						.font(.system(size: 10))
						.foregroundColor(.red)
				}
				.buttonStyle(.plain)
				.hoverTooltip("Delete permanently")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			// Auto-stash will make room if at the tab limit
			Task {
				await promptVM.unstashTab(stashed.id)
				isPresented = false
			}
		}
		.onHover { hovering in
			hoveredStashedID = hovering ? stashed.id : nil
		}
	}
}

private extension Date {
	func relativeTimeString() -> String {
		let now = Date()
		let interval = now.timeIntervalSince(self)
		
		if interval < 60 {
			return "just now"
		} else if interval < 3600 {
			let minutes = Int(interval / 60)
			return "\(minutes)m ago"
		} else if interval < 86400 {
			let hours = Int(interval / 3600)
			return "\(hours)h ago"
		} else {
			let days = Int(interval / 86400)
			return "\(days)d ago"
		}
	}
}

private extension Array {
	subscript(safe index: Index) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
