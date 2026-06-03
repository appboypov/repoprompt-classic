import SwiftUI
import Combine

enum PromptTab {
	case compose, chat
}

struct TabbedPromptView: View {
	@ObservedObject var promptManager: PromptViewModel
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var aiResponseViewModel: AIResponseViewModel
	@ObservedObject var diffViewModel: DiffViewModel
	@ObservedObject var chatViewModel: ChatViewModel
	@ObservedObject var apiSettingsViewModel: APISettingsViewModel
	@ObservedObject var windowState: WindowState
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	@Binding var currentTab: PromptTab
	@Binding var showSettings: Bool
	@Binding var currentView: ViewType
	var selectFileForPreview: (FileViewModel?) -> Void
	
	@State private var hoveredTab: PromptTab?
	@State private var showSettingsPopover = false
	@State private var chatBusyTabs: Set<UUID> = []
	@State private var isSettingsHovered = false
	
	var body: some View {
		VStack(spacing: 0) {
			tabSelector
			
			Divider()

			ComposeTabBar(
				promptVM: promptManager,
				discoverVM: windowState.discoverAgentViewModel,
				chatBusyTabs: chatBusyTabs
			)
			.padding(.top, 8)

			Divider()
			
			tabContent
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.onReceive(
			windowState.workspaceManager.$tabsWithActiveChat
		) { tabs in
			chatBusyTabs = tabs
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .switchToChatView)
		) { note in
			if let id = note.userInfo?["windowID"] as? Int,
				id != windowState.windowID { return }
			currentTab = .chat
		}
		.onChange(of: showSettingsPopover) { _, newValue in
			guard newValue else { return }
			NotificationCenter.default.post(
				name: .showSettingsPopover,
				object: windowState
			)
			showSettingsPopover = false
		}
	}
	
	private var tabSelector: some View {
		HStack(spacing: 0) {
			Divider().frame(width: 0.5, height: 32).allowsHitTesting(false)
			tabButton(for: .compose)
			tabButton(for: .chat)
			settingsButton
		}
		//.background(Color(NSColor.controlBackgroundColor))
	}
	
	private func tabButton(for tab: PromptTab) -> some View {
		Button(action: { currentTab = tab }) {
			HStack(spacing: 4) {
				Image(systemName: iconName(for: tab))
					.font(fontPreset.font)
				Text(tabTitle(for: tab))
					.font(fontPreset.font)
				
				// Progress indicator for chat tab - always present to maintain layout
				if tab == .chat {
					ProgressView()
						.scaleEffect(0.5)
						.frame(width: 12, height: 12)
						.opacity(chatViewModel.isAnySessionStreaming ? 1.0 : 0.0)
						.padding(.leading, 4)
				}
			}
			.padding(.leading, tab == .chat ? 16 : 0)
			.foregroundColor(currentTab == tab ? .accentColor : (hoveredTab == tab ? .primary : .secondary))
			.frame(maxWidth: .infinity, minHeight: 32)
			.background(hoveredTab == tab ? Color.primary.opacity(0.1) : Color.clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.background(
			VStack {
				Spacer()
				if currentTab == tab {
					Color.accentColor.frame(height: 1)
				}
			}
		)
		.onHover { isHovered in
			hoveredTab = isHovered ? tab : nil
		}
		.hoverTooltip(tooltipText(for: tab))
	}
	
	private func tabTitle(for tab: PromptTab) -> String {
		switch tab {
		case .compose: return "Compose"
		case .chat: return "Chat"
		}
	}
	
	private func iconName(for tab: PromptTab) -> String {
		switch tab {
		case .compose: return "pencil"
		case .chat: return "bubble.left.and.bubble.right"
		}
	}
	
	private func tooltipText(for tab: PromptTab) -> String {
		switch tab {
		case .compose: return "Generate prompts from selected files"
		case .chat: return "Chat with AI about your codebase and apply edits"
		}
	}
	
	private var settingsButton: some View {
		Button {
			NotificationCenter.default.post(
				name: .showSettingsPopover,
				object: windowState
			)
		} label: {
			ZStack {
				Color.clear

				Image(systemName: "gearshape")
					.font(.system(size: 16))
					.foregroundColor(isSettingsHovered ? .primary : .secondary)
			}
			.frame(width: 32, height: 32)
			.background(isSettingsHovered ? Color.primary.opacity(0.1) : Color.clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.hoverTooltip("Settings")
		.onHover { hovering in
			isSettingsHovered = hovering
		}
	}
	
	@ViewBuilder
	private var tabContent: some View {
		switch currentTab {
		case .compose:
			PromptView(promptManager: promptManager,
						fileManager: fileManager,
						discoverAgentViewModel: windowState.discoverAgentViewModel,
						windowState: windowState,
						diffViewModel: diffViewModel,
						windowID: windowState.windowID,
						currentTab: $currentTab,
						currentView: $currentView,
						showSettings: $showSettings,
						showSettingsPopover: $showSettingsPopover,
						selectFileForPreview: selectFileForPreview)
		case .chat:
			ChatView(viewModel: chatViewModel,
						promptViewModel: promptManager,
						windowID: windowState.windowID,
						showSettingsPopover: $showSettingsPopover)
		}
	}
}
