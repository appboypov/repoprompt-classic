//
//  ChatListPopover.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-27.
//

import SwiftUI
import AppKit

@MainActor
struct ChatListPopover: View {
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	@State private var hoveredSessionID: UUID?
	@State private var isShowingRenameAlertPopover: Bool = false
	@State private var sessionToRenamePopover: ChatSession? = nil
	@State private var newSessionNamePopover: String = ""
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	// Search and section state
	@State private var searchText: String = ""
	@State private var isInProgressExpanded: Bool = true
	@State private var isThisTabExpanded: Bool = true
	@State private var isAllExpanded: Bool = false
	
	// Chat history limit setting (using Int to store the enum raw value)
	@AppStorage("chatHistoryLimit") private var chatHistoryLimitRaw: Int = ChatHistoryLimit.fifty.rawValue
	
	// Computed binding to work with the enum
	private var chatHistoryLimit: Binding<ChatHistoryLimit> {
		Binding(
			get: {
				// Handle the case where no setting exists (0) by defaulting to 50 sessions
				return chatHistoryLimitRaw == 0 ? .fifty : ChatHistoryLimit.from(rawValue: chatHistoryLimitRaw)
			},
			set: { newValue in
				chatHistoryLimitRaw = newValue.rawValue
			}
		)
	}
	
	// MARK: - Session Lists
	
	private var streamingSessions: [ChatSession] {
		viewModel.sessions
			.filter { viewModel.isSessionStreaming($0.id) }
			.filter { matchesSearch($0) }
			.sorted {
				let lhsCurrent = $0.id == viewModel.currentSessionID
				let rhsCurrent = $1.id == viewModel.currentSessionID
				if lhsCurrent != rhsCurrent { return lhsCurrent }
				return $0.savedAt > $1.savedAt
			}
	}
	
	private var thisTabSessions: [ChatSession] {
		let streamingIDs = Set(streamingSessions.map(\.id))
		let currentTabID = promptViewModel.activeComposeTabID
		return viewModel.sessions
			.filter { $0.composeTabID == currentTabID }
			.filter { !streamingIDs.contains($0.id) }
			.filter { matchesSearch($0) }
			.sorted { $0.savedAt > $1.savedAt }
	}
	
	private var allSessions: [ChatSession] {
		let streamingIDs = Set(streamingSessions.map(\.id))
		let currentTabID = promptViewModel.activeComposeTabID
		return viewModel.sessions
			.filter { $0.composeTabID != currentTabID } // Exclude current tab (shown above)
			.filter { !streamingIDs.contains($0.id) }
			.filter { matchesSearch($0) }
			.sorted { $0.savedAt > $1.savedAt }
	}
	
	private func matchesSearch(_ session: ChatSession) -> Bool {
		guard !searchText.isEmpty else { return true }
		let query = searchText.lowercased()
		// Match session name
		if session.name.lowercased().contains(query) { return true }
		// Match tab name
		if tabName(for: session).lowercased().contains(query) { return true }
		return false
	}
	
	private func tabName(for session: ChatSession) -> String {
		guard let tabID = session.composeTabID else { return "Unassigned" }
		if let tab = promptViewModel.currentComposeTabs.first(where: { $0.id == tabID }) {
			return tab.name
		}
		let shortID = String(tabID.uuidString.prefix(6))
		return "Missing Tab (\(shortID))"
	}
	
	private var currentTabName: String {
		guard let tabID = promptViewModel.activeComposeTabID,
			let tab = promptViewModel.currentComposeTabs.first(where: { $0.id == tabID }) else {
			return "This Tab"
		}
		return tab.name
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Header with gear menu
			HStack {
				Text("Chats")
					.font(fontPreset.headlineFont)
				Spacer()

				Menu {
					Section("Chat Retention") {
						Picker("Keep", selection: chatHistoryLimit) {
							ForEach(ChatHistoryLimit.allCases, id: \.self) { limit in
								Text(limit.displayName).tag(limit)
							}
						}
					}

					Divider()

					Button(role: .destructive) {
						Task {
							await viewModel.clearAllChats()
						}
					} label: {
						Label("Clear All Chats", systemImage: "trash")
					}
				} label: {
					Image(systemName: "gearshape")
						.foregroundColor(.secondary)
						.imageScale(.medium)
				}
				.menuStyle(.borderlessButton)
				.frame(width: 28, height: 28)
			}

			// Search field
			HStack {
				Image(systemName: "magnifyingglass")
					.foregroundColor(.secondary)
				TextField("Search chats...", text: $searchText)
					.textFieldStyle(.plain)
					.font(fontPreset.standardFont)
				if !searchText.isEmpty {
					Button {
						searchText = ""
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.secondary)
					}
					.buttonStyle(.plain)
				}
			}
			.padding(8)
			.background(Color.primary.opacity(0.05))
			.cornerRadius(8)

			Divider()
			
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 4) {
					// In Progress section (streaming sessions)
					if !streamingSessions.isEmpty {
						collapsibleSectionHeader(title: "In Progress", count: streamingSessions.count, isExpanded: $isInProgressExpanded)
						if isInProgressExpanded {
							ForEach(streamingSessions) { session in
								chatRow(session)
							}
						}
					}
					
					// This Tab section
					collapsibleSectionHeader(title: currentTabName, count: thisTabSessions.count, isExpanded: $isThisTabExpanded)
					if isThisTabExpanded {
						if thisTabSessions.isEmpty {
							Text("No chats in this tab.")
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
								.padding(.horizontal, 8)
								.padding(.vertical, 4)
						} else {
							ForEach(thisTabSessions) { session in
								chatRow(session)
							}
						}
					}
					
					// All (Other Tabs) section
					collapsibleSectionHeader(title: "Other Tabs", count: allSessions.count, isExpanded: $isAllExpanded)
					if isAllExpanded {
						if allSessions.isEmpty {
							Text("No chats in other tabs.")
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
								.padding(.horizontal, 8)
								.padding(.vertical, 4)
						} else {
							ForEach(allSessions) { session in
								chatRow(session)
							}
						}
					}
				}
				.padding(.vertical, 6)
				.padding(.trailing, 8) // Space for scrollbar
			}
			.frame(minHeight: fontPreset.scaledMetric(280), maxHeight: fontPreset.scaledClamped(400, max: 560))
		}
		.padding()
		.frame(width: fontPreset.scaledClamped(380, max: 520))
		// Add alert for renaming
		.onChange(of: searchText) { _, newValue in
			// Auto-expand Other Tabs when search has matches there
			if !newValue.isEmpty && !allSessions.isEmpty {
				isAllExpanded = true
			}
		}
		.alert("Rename Chat", isPresented: $isShowingRenameAlertPopover, presenting: sessionToRenamePopover) { session in
			TextField("Enter new name", text: $newSessionNamePopover)
			Button("Save") {
				if let session = sessionToRenamePopover, !newSessionNamePopover.isEmpty {
					viewModel.renameSession(id: session.id, newName: newSessionNamePopover)
				}
				resetRenamePopoverState()
			}
			Button("Cancel", role: .cancel) {
				resetRenamePopoverState()
			}
		} message: { _ in
			Text("Enter a new name for this chat session.")
		}
	}
	
	// MARK: - Delete Session
	private func deleteSession(_ session: ChatSession) async {
		await viewModel.deleteSession(session)
	}

	// MARK: - Rename Helpers
	private func resetRenamePopoverState() {
		isShowingRenameAlertPopover = false
		sessionToRenamePopover = nil
		newSessionNamePopover = ""
	}
	
	private func collapsibleSectionHeader(
		title: String,
		count: Int,
		isExpanded: Binding<Bool>
	) -> some View {
		Button {
			withAnimation(.easeInOut(duration: 0.2)) {
				isExpanded.wrappedValue.toggle()
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "chevron.right")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
					.foregroundColor(.secondary)
					.rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
					.animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
				Text(title)
					.font(fontPreset.subheadlineFont)
					.foregroundColor(.primary)
				Spacer()
				Text("\(count)")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
	
	private func chatRow(_ session: ChatSession) -> some View {
		let isStreaming = viewModel.isSessionStreaming(session.id)
		let currentTabID = promptViewModel.activeComposeTabID
		let isInOtherTabStreaming = isStreaming && session.composeTabID != currentTabID
		let otherTabName: String? = {
			guard isInOtherTabStreaming, let tabID = session.composeTabID else { return nil }
			return promptViewModel.currentComposeTabs.first(where: { $0.id == tabID })?.name
				?? "Tab \(tabID.uuidString.prefix(4))"
		}()

		return ChatListRow(
			session: session,
			tabName: tabName(for: session),
			isActive: session.id == viewModel.currentSessionID,
			isHovered: session.id == hoveredSessionID,
			isStreaming: isStreaming,
			isInOtherTabStreaming: isInOtherTabStreaming,
			otherTabName: otherTabName,
			onDelete: {
				Task {
					await deleteSession(session)
				}
			},
			onSelect: {
				Task {
					await viewModel.switchToSession(session.id)
				}
			},
			onRename: {
				sessionToRenamePopover = session
				newSessionNamePopover = session.name // Pre-fill
				isShowingRenameAlertPopover = true
			},
			onCancelStream: {
				Task { await viewModel.cancelAIResponse(in: session.id, skipPartialParseAndSave: false) }
			},
			onSave: {
				Task {
					do {
						_ = try await viewModel.autosaveSession(session)
					} catch {
						print("Error saving session: \(error)")
					}
				}
			}
		)
		.onHover { isHovered in
			hoveredSessionID = isHovered ? session.id : nil
		}
	}
}

// MARK: - ChatListRow
struct ChatListRow: View {
	let session: ChatSession
	let tabName: String
	let isActive: Bool
	let isHovered: Bool
	let isStreaming: Bool
	let isInOtherTabStreaming: Bool
	let otherTabName: String?
	let onDelete: () -> Void
	let onSelect: () -> Void
	let onRename: () -> Void
	let onCancelStream: () -> Void
	let onSave: () -> Void
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 3) {
				// Primary line: name + badges
				HStack(spacing: 6) {
					Text(session.name)
						.font(fontPreset.standardFont)
						.fontWeight(isActive ? .medium : .regular)
						.lineLimit(1)
						.truncationMode(.tail)

					// Streaming spinner (same tab only)
					if isStreaming && !isInOtherTabStreaming {
						ProgressView()
							.scaleEffect(0.55)
							.frame(width: 12, height: 12)
					}

					// Badge logic
					if isActive {
						activeBadge
					} else if isInOtherTabStreaming, let tabName = otherTabName {
						streamingInOtherTabBadge(tabName: tabName)
					}
				}

				// Secondary line: metadata
				Text(metadataText)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}

			Spacer(minLength: 8)

			// Hover actions
			hoverActions
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(rowBackground)
		.cornerRadius(8)
		.contentShape(Rectangle())
		.onTapGesture(perform: onSelect)
		.contextMenu {
			if isStreaming {
				Button("Cancel Response", action: onCancelStream)
			}
			Button("Save", action: onSave)
			Button("Rename", action: onRename)
			Button("Delete", role: .destructive, action: onDelete)
			Divider()
			Button("Copy Chat ID") {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(session.shortID, forType: .string)
			}
		}
	}

	// MARK: - Row Background
	private var rowBackground: some View {
		RoundedRectangle(cornerRadius: 8)
			.fill(isActive ? Color.blue.opacity(0.08) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
	}

	// MARK: - Hover Actions
	private var hoverActions: some View {
		HStack(spacing: 6) {
			// Cancel/Stop button - only present when streaming
			if isStreaming {
				HoverActionButton(
					icon: "stop.circle.fill",
					color: .orange,
					action: onCancelStream
				)
			}

			// Rename button - always takes space, visible on hover
			HoverActionButton(
				icon: "pencil",
				color: .secondary,
				action: onRename
			)
			.opacity(isHovered ? 1 : 0)

			// Delete button - always takes space, visible on hover
			HoverActionButton(
				icon: "trash",
				color: .red.opacity(0.8),
				action: onDelete
			)
			.opacity(isHovered ? 1 : 0)
		}
	}

	// MARK: - Metadata
	private var metadataText: String {
		let parts = [tabName, "\(session.effectiveMessageCount) msgs", session.savedAt.relativeTimeString()]
		return parts.filter { !$0.isEmpty }.joined(separator: " • ")
	}

	// MARK: - Active Badge (Blue)
	private var activeBadge: some View {
		Text("Active")
			.font(fontPreset.captionFont)
			.foregroundColor(.blue)
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
			.background(
				Capsule()
					.fill(Color.blue.opacity(0.12))
			)
			.overlay(
				Capsule()
					.strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
			)
	}

	// MARK: - Streaming in Other Tab Badge (Orange)
	private func streamingInOtherTabBadge(tabName: String) -> some View {
		HStack(spacing: 4) {
			ProgressView()
				.scaleEffect(0.5)
				.frame(width: 10, height: 10)
			Text(tabName)
				.font(fontPreset.captionFont)
				.lineLimit(1)
		}
		.foregroundColor(.orange)
		.padding(.horizontal, 8)
		.padding(.vertical, 2)
		.background(
			Capsule()
				.fill(Color.orange.opacity(0.12))
		)
		.overlay(
			Capsule()
				.strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
		)
	}
}

private extension Date {
	func relativeTimeString() -> String {
		let now = Date()
		let interval = now.timeIntervalSince(self)
		if interval < 60 {
			return "just now"
		}
		let minutes = Int(interval / 60)
		if minutes < 60 {
			return "\(minutes)m ago"
		}
		let hours = Int(interval / 3600)
		if hours < 24 {
			return "\(hours)h ago"
		}
		let days = Int(interval / 86400)
		if days < 7 {
			return "\(days)d ago"
		}
		let weeks = Int(interval / (86400 * 7))
		if weeks < 4 {
			return "\(weeks)w ago"
		}
		let months = Int(interval / (86400 * 30))
		if months < 12 {
			return "\(months)mo ago"
		}
		let years = Int(interval / (86400 * 365))
		return "\(years)y ago"
	}
}

// MARK: - Hover Action Button
private struct HoverActionButton: View {
	let icon: String
	let color: Color
	let action: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			Image(systemName: icon)
				.foregroundColor(isHovered ? color.opacity(1) : color.opacity(0.8))
				.imageScale(.medium)
				.frame(width: 20, height: 20)
				.background(
					Circle()
						.fill(isHovered ? color.opacity(0.15) : Color.clear)
				)
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
	}
}
