import SwiftUI
import AppKit

struct ChatTopBar: View {
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject var promptViewModel: PromptViewModel

	@State private var showChatListPopover = false
	@State private var showStoredPrompts = false
	@State private var hoveredSessionID: UUID?
	@State private var isShowingRenameAlert = false
	@State private var sessionToRename: ChatSession?
	@State private var newSessionName = ""

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		HStack(spacing: 8) {
			PromptsButton(
				showStoredPrompts: $showStoredPrompts,
				promptViewModel: promptViewModel
			)

			Divider()
				.frame(height: 16)

			ScrollView(.horizontal, showsIndicators: false) {
				inlineSessions
			}

			allChatsButton
			newChatButton
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.onReceive(NotificationCenter.default.publisher(for: .showPromptsPopover)) { notification in
			if let windowID = notification.userInfo?["windowID"] as? Int,
			   windowID == promptViewModel.windowID {
				showStoredPrompts = true
			}
		}
		.alert("Rename Chat", isPresented: $isShowingRenameAlert, presenting: sessionToRename) { session in
			TextField("Enter new name", text: $newSessionName)
			Button("Save") {
				Task {
					await viewModel.renameSession(id: session.id, newName: newSessionName)
					resetRenameState()
				}
			}
			Button("Cancel", role: .cancel) {
				resetRenameState()
			}
		} message: { session in
			Text("Enter a new name for '\(session.name)'")
		}
	}

	private func resetRenameState() {
		isShowingRenameAlert = false
		sessionToRename = nil
		newSessionName = ""
	}
}

private extension ChatTopBar {
	var newChatButton: some View {
		Button {
			Task { @MainActor in
				await viewModel.startNewChatSession()
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "plus")
					.font(fontPreset.standardFont)
				Text("New")
					.font(fontPreset.standardFont)
			}
		}
		.buttonStyle(CustomButtonStyle())
		.keyboardShortcut("n", modifiers: [.command, .shift])
		.hoverTooltip("New chat (Cmd+Shift+N)")
	}
	
	@ViewBuilder
	var inlineSessions: some View {
		let sessions = inlineSessionList
		if !sessions.isEmpty {
			HStack(spacing: 6) {
				ForEach(sessions) { session in
					sessionChip(session)
				}
			}
		}
	}
	
	var allChatsButton: some View {
		let showOtherStreaming = otherStreamingCount > 0
		return Button {
			showChatListPopover.toggle()
		} label: {
			HStack(spacing: 4) {
				if showOtherStreaming {
					ProgressView()
						.scaleEffect(0.55)
						.frame(width: 14, height: 14)
				} else {
					Image(systemName: "bubble.left.and.bubble.right")
						.font(fontPreset.standardFont)
				}
				Text("Chats")
					.font(fontPreset.standardFont)
			}
		}
		.buttonStyle(CustomButtonStyle())
		.hoverTooltip(showOtherStreaming ? "Chats (\(otherStreamingCount) streaming)" : "All chats")
		.popover(isPresented: $showChatListPopover, arrowEdge: .bottom) {
			ChatListPopover(
				viewModel: viewModel,
				promptViewModel: promptViewModel
			)
		}
	}
	
	func sessionChip(_ session: ChatSession) -> some View {
		let isActive = session.id == viewModel.currentSessionID
		let isHovered = session.id == hoveredSessionID
		let isStreaming = viewModel.isSessionStreaming(session.id)

		return Button {
			Task { @MainActor in
				await viewModel.switchToSession(session.id)
			}
		} label: {
			HStack(spacing: 4) {
				Text(session.name)
					.font(fontPreset.standardFont)
					.lineLimit(1)
					.truncationMode(.tail)
				if isStreaming {
					ProgressView()
						.scaleEffect(0.6)
						.frame(width: 10, height: 10)
				} else {
					// X button - always takes space, visible only on hover
					DeleteChipButton {
						Task { await viewModel.deleteSession(session) }
					}
					.opacity(isHovered ? 1 : 0)
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 16)
					.fill(isActive ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 16)
					.stroke(isActive ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
			)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { isHovered in
			hoveredSessionID = isHovered ? session.id : nil
		}
		.contextMenu {
			contextMenuContent(for: session)
		}
		.hoverTooltip(session.name)
	}

	@ViewBuilder
	func contextMenuContent(for session: ChatSession) -> some View {
		if viewModel.isSessionStreaming(session.id) {
			Button("Cancel Response") {
				Task { await viewModel.cancelAIResponse(in: session.id, skipPartialParseAndSave: false) }
			}
		}
		Button("Save") {
			Task {
				do {
					_ = try await viewModel.autosaveSession(session)
				} catch {
					print("Error saving session: \(error)")
				}
			}
		}
		Button("Rename") {
			sessionToRename = session
			newSessionName = session.name
			isShowingRenameAlert = true
		}
		Button("Delete", role: .destructive) {
			Task { await viewModel.deleteSession(session) }
		}
		Divider()
		Button("Copy Chat ID") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(session.shortID, forType: .string)
		}
	}
	
	var inlineSessionList: [ChatSession] {
		let sorted = viewModel.activeTabSessions.sorted {
			if !$0.hasMessages && $1.hasMessages { return true }
			if $0.hasMessages && !$1.hasMessages { return false }
			return $0.savedAt > $1.savedAt
		}
		var list = Array(sorted.prefix(10))
		if let currentID = viewModel.currentSessionID,
			let currentSession = viewModel.activeTabSessions.first(where: { $0.id == currentID }),
			!list.contains(where: { $0.id == currentID }) {
			if list.count >= 10 {
				list.removeLast()
			}
			list.insert(currentSession, at: 0)
		}
		return list
	}
	
	var otherStreamingCount: Int {
		viewModel.sessions.filter {
			viewModel.isSessionStreaming($0.id) && $0.id != viewModel.currentSessionID
		}.count
	}

}

// MARK: - Delete Chip Button
private struct DeleteChipButton: View {
	let action: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: 9, weight: .medium))
				.foregroundColor(isHovered ? .primary : .secondary)
				.frame(width: 14, height: 14)
				.background(
					Circle()
						.fill(isHovered ? Color.primary.opacity(0.15) : Color.clear)
				)
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
	}
}
