//
//  PlanDualActionButton.swift
//  RepoPrompt
//

import SwiftUI

/// A dual-action button for plan actions: main action (Use as Prompt) + secondary action (Preview)
struct PlanDualActionButton: View {
	let icon: String
	let label: String
	let mainAction: () -> Void
	let secondaryIcon: String
	let secondaryAction: () -> Void
	let helpText: String?
	
	@State private var isHovering = false
	@State private var isHoveringMainPart = false
	@State private var isHoveringSecondaryPart = false
	@State private var isPressedMain = false
	@State private var isPressedSecondary = false
	
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.isEnabled) private var isEnabled
	
	private let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
	private let disabledColor = Color(nsColor: .controlBackgroundColor).opacity(0.25)
	private let lineColor = Color(NSColor.systemGray)
	
	init(
		icon: String,
		label: String,
		mainAction: @escaping () -> Void,
		secondaryIcon: String,
		secondaryAction: @escaping () -> Void,
		helpText: String? = nil
	) {
		self.icon = icon
		self.label = label
		self.mainAction = mainAction
		self.secondaryIcon = secondaryIcon
		self.secondaryAction = secondaryAction
		self.helpText = helpText
	}
	
	var body: some View {
		HStack(spacing: 0) {
			// Main button
			Button(action: mainAction) {
				HStack(spacing: 4) {
					Image(systemName: icon)
						.font(.callout)
					Text(label)
						.font(.callout)
						.lineLimit(1)
						.fixedSize(horizontal: true, vertical: false)
				}
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(backgroundForPart(isHovering: isHoveringMainPart, isPressed: isPressedMain))
				.contentShape(Rectangle())
			}
			.buttonStyle(PlainButtonStyle())
			.onHover { hovering in
				isHoveringMainPart = hovering
			}
			.simultaneousGesture(
				DragGesture(minimumDistance: 0)
					.onChanged { _ in isPressedMain = true }
					.onEnded { _ in isPressedMain = false }
			)
			
			// Divider
			Rectangle()
				.fill(lineColor.opacity(0.3))
				.frame(width: 1)
				.padding(.vertical, 6)
			
			// Secondary button (preview)
			Button(action: secondaryAction) {
				Image(systemName: secondaryIcon)
					.font(.callout)
					.foregroundColor(isEnabled ? .secondary : .gray)
					.padding(.horizontal, 8)
					.padding(.vertical, 6)
					.background(backgroundForPart(isHovering: isHoveringSecondaryPart, isPressed: isPressedSecondary))
					.contentShape(Rectangle())
			}
			.buttonStyle(PlainButtonStyle())
			.onHover { hovering in
				isHoveringSecondaryPart = hovering
			}
			.simultaneousGesture(
				DragGesture(minimumDistance: 0)
					.onChanged { _ in isPressedSecondary = true }
					.onEnded { _ in isPressedSecondary = false }
			)
		}
		.foregroundColor(isEnabled ? foregroundColor : .gray)
		.clipShape(RoundedRectangle(cornerRadius: 16))
		.overlay(
			RoundedRectangle(cornerRadius: 16)
				.stroke(borderColorForState, lineWidth: 0.5)
		)
		.onHover { hovering in
			isHovering = hovering
		}
		.hoverTooltip(helpText)
	}
	
	// MARK: - Backgrounds
	
	private func backgroundForPart(isHovering: Bool, isPressed: Bool) -> some View {
		Group {
			if !isEnabled {
				disabledColor
			} else if isPressed {
				backgroundColor.overlay(Color.primary.opacity(0.15))
			} else if isHovering {
				backgroundColor.overlay(Color.primary.opacity(0.05))
			} else {
				Color.clear
			}
		}
	}
	
	private var backgroundForState: some View {
		Group {
			if !isEnabled {
				disabledColor
			} else if isPressedMain || isPressedSecondary {
				backgroundColor.overlay(Color.primary.opacity(0.15))
			} else if isHovering {
				backgroundColor.overlay(Color.primary.opacity(0.05))
			} else {
				Color.clear
			}
		}
	}
	
	private var borderColorForState: Color {
		if !isEnabled {
			return lineColor.opacity(0.25)
		} else if isPressedMain || isPressedSecondary {
			return lineColor.opacity(0.5)
		} else if isHovering {
			return lineColor
		} else {
			return lineColor.opacity(0.75)
		}
	}
	
	private var foregroundColor: Color {
		colorScheme == .dark ? .white : .black
	}
}
