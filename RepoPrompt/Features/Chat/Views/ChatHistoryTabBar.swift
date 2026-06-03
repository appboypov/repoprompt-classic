import SwiftUI

@MainActor
struct ChatHistoryTabBar: View {
	@ObservedObject var viewModel: ChatViewModel
	@Binding var showHistoryPopover: Bool
	@Binding var currentTab: PromptTab
	
	@State private var hoveredTabID: UUID?
	@State private var hoveredButtonType: HoveredButton?
	// Add state for renaming alert
	@State private var isShowingRenameAlert: Bool = false
	@State private var sessionToRename: ChatSession? = nil
	@State private var newSessionName: String = ""
	
	private enum HoveredButton {
		case new
		case history
	}
	
	var body: some View {
		HStack(spacing: 8) {
			headerLabel
			newChatButton
			chatTabs
			Spacer()
			historyButton
		}
		.padding(.horizontal, 16)
		.padding(.top, 6)
		.padding(.bottom, 5)
		//.animation(.easeInOut(duration: 0.2), value: viewModel.sessions.count)
		// Add alert for renaming
		.alert("Rename Chat", isPresented: $isShowingRenameAlert, presenting: sessionToRename) { session in
			TextField("Enter new name", text: $newSessionName)
			Button("Save") {
				if let session = sessionToRename, !newSessionName.isEmpty {
					viewModel.renameSession(id: session.id, newName: newSessionName)
				}
				resetRenameState()
			}
			Button("Cancel", role: .cancel) {
				resetRenameState()
			}
		} message: { _ in
			Text("Enter a new name for this chat session.")
		}
	}
	
	// MARK: - New Chat Button
	private var newChatButton: some View {
		Button {
			Task { @MainActor in
				await viewModel.startNewChatSession()
				currentTab = .chat
			}
		} label: {
			Image(systemName: "plus")
				.foregroundColor(.accentColor)
				.frame(width: 32, height: 32)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(hoveredButtonType == .new ? Color.accentColor.opacity(0.1) : Color.clear)
				)
		}
		.buttonStyle(PlainButtonStyle())
		.keyboardShortcut("n", modifiers: [.command, .shift]) // Add the keyboard shortcut
		.onHover { isHovered in
			hoveredButtonType = isHovered ? .new : nil
		}
		.hoverTooltip("New chat for this tab (⌘⇧N)")
	}
	
	// MARK: - Chat Tabs
	private var chatTabs: some View {
		ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 2) {
					ForEach(
						viewModel.activeTabSessions
							.sorted {
								// Pin sessions with no user messages to the front
								if !$0.hasMessages && $1.hasMessages {
									return true
								} else if $0.hasMessages && !$1.hasMessages {
									return false
								}
								// Otherwise keep newest-first order
								return $0.savedAt > $1.savedAt
							}
							.prefix(10)
					) { session in
						TabItemView(
							session: session,
							isActive: session.id == viewModel.currentSessionID,
							isHovered: session.id == hoveredTabID,
							isStreaming: viewModel.isSessionStreaming(session.id),
							onDelete: {
								Task { await deleteSession(session) }
							}
						)
						.id(session.id)
						.onTapGesture {
							Task { @MainActor in
								await viewModel.switchToSession(session.id)
								currentTab = .chat
							}
						}
						.onHover { isHovered in
							hoveredTabID = isHovered ? session.id : nil
						}
						.contextMenu {
							contextMenuContent(for: session)
						}
					}
				}
				.padding(.leading, 8)
			}
			.onChange(of: viewModel.currentSessionID) { _, newID in
				withAnimation {
					proxy.scrollTo(newID, anchor: .center)
				}
			}
		}
	}
	
	// MARK: - History Button
	private var historyButton: some View {
		Button {
			showHistoryPopover = true
		} label: {
			Image(systemName: "bubble.left.and.bubble.right")
				.imageScale(.large)
				.foregroundColor(hoveredButtonType == .history ? .accentColor : .secondary)
				.frame(width: 32, height: 32)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(hoveredButtonType == .history ? Color.accentColor.opacity(0.1) : Color.clear)
				)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { isHovered in
			hoveredButtonType = isHovered ? .history : nil
		}
		.hoverTooltip("Chats")
		.popover(isPresented: $showHistoryPopover) {
			ChatListPopover(
				viewModel: viewModel,
				promptViewModel: viewModel.promptViewModel
			)
		}
	}

	private var headerLabel: some View {
		HStack(spacing: 4) {
			Text("Chats")
				.foregroundColor(.secondary)
			if let tabName = activeTabName {
				Text("•")
					.foregroundColor(.secondary)
				Text(tabName)
					.foregroundColor(.primary)
					.lineLimit(1)
			}
		}
		.font(.caption)
	}

	private var activeTabName: String? {
		guard let activeID = viewModel.promptViewModel.activeComposeTabID,
			let tab = viewModel.promptViewModel.currentComposeTabs.first(where: { $0.id == activeID }) else {
			return nil
		}
		return tab.name
	}
	
	// MARK: - Context Menu
	private func contextMenuContent(for session: ChatSession) -> some View {
		Group {
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
			// Add Rename option
			Button("Rename") {
				sessionToRename = session
				newSessionName = session.name // Pre-fill with current name
				isShowingRenameAlert = true
			}
			Button("Delete", role: .destructive) {
				Task {
					await deleteSession(session)
				}
			}
			Divider()
			Button("Copy Chat ID") {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(session.shortID, forType: .string)
			}
		}
	}
	
	// MARK: - Delete Session
	private func deleteSession(_ session: ChatSession) async {
		await viewModel.deleteSession(session)
	}
	
	// MARK: - Rename Helpers
	private func resetRenameState() {
		isShowingRenameAlert = false
		sessionToRename = nil
		newSessionName = ""
	}
}

// MARK: - TabItemView
struct TabItemView: View {
	let session: ChatSession
	let isActive: Bool
	let isHovered: Bool
	let isStreaming: Bool
	let onDelete: () -> Void
	@Environment(\.font) private var envFont
	
	var body: some View {
		HStack(spacing: 4) {
			Text(session.name)
				.font((envFont ?? .body).weight(.regular))
				.lineLimit(1)
			
			if isStreaming {
				ProgressView()
					.scaleEffect(0.6)
					.frame(width: 10, height: 10)
			}
			
			// If you want the small "X" button on hover, uncomment this:
			/*
			 if isHovered {
			 Button(action: onDelete) {
			 Image(systemName: "xmark")
			.font(envFont.weight(.light).scale(0.9))
			 .foregroundColor(.secondary)
			 }
			 .buttonStyle(PlainButtonStyle())
			 }
			 */
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(backgroundColor)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.stroke(Color.accentColor.opacity(isActive ? 0.5 : 0), lineWidth: 1)
		)
	}
	
	private var backgroundColor: Color {
		if isActive {
			return isHovered ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.2)
		}
		return isHovered ? Color.gray.opacity(0.1) : Color.clear
	}
}
