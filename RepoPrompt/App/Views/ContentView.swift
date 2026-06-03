import SwiftUI
import Combine

// MARK: - ContentView
struct ContentView: View {
	@StateObject private var viewModel: ContentViewModel
	@StateObject private var workspaceApprovalManager = WorkspaceApprovalManager.shared
	
	// Existing states
	@State private var showWorkspaceSetup = false

	// State for the missing bookmarks sheet
	@State private var showMissingBookmarksSheet = false

	@State var appearCounter: Int = 0
	@State private var shouldAutoRestoreSidebarAfterAIQuery: Bool = false

	@State private var columnVisibility: NavigationSplitViewVisibility = .all
	@State private var preferredColumn: NavigationSplitViewColumn = .sidebar

	// Sheet for naming a brand-new preset
	@State private var showCreatePresetSheet = false

	// Stable state for toolbar popovers so they survive toolbar re-evaluation
	@State private var showMCPServerPopover = false
	@State private var showMCPStatusSheet = false
	@State private var showRecommendationsPopover = false
	@State private var showWorkspaceSwitchOverlay = false
	
	// Recommendation wizard view model (lazy initialized)
	@State private var recommendationWizardViewModel: RecommendationWizardViewModel?

	/// Initialize with a single WindowState,
	/// then build a ContentViewModel from it.
	init(windowState: WindowState) {
		_viewModel = StateObject(wrappedValue: ContentViewModel(state: windowState))
	}

	var body: some View {
		let mainContent = ZStack {
			Group {
				if viewModel.rootRoute == .workspaceEntry {
					WorkspaceEntryRootView(
						workspaceManager: viewModel.workspaceManager,
						windowState: viewModel.state,
						tab: $viewModel.workspaceEntryTab,
						onboardingViewModel: viewModel.onboardingViewModel,
						onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
						onSwitchToAgent: {
							viewModel.state.uiMode = .agent
						}
					)
				} else if viewModel.uiMode == .agent {
					AgentModeView(
						windowState: viewModel.state,
						agentModeVM: viewModel.state.agentModeViewModel,
						promptManager: viewModel.promptManager
					)
				} else {
					NavigationSplitView(
						columnVisibility: $columnVisibility,
						preferredCompactColumn: $preferredColumn
					) {
						// Sidebar column
						sidebarView
							.navigationSplitViewColumnWidth(
								min: AppSidebarSizing.minWidth,
								ideal: AppSidebarSizing.idealWidth,
								max: AppSidebarSizing.maxWidth
							)
					} detail: {
						// Detail column
						detailView
					}
				} // end mode conditional
			}
			.blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
			.animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

			if showWorkspaceSwitchOverlay {
				workspaceSwitchLoadingOverlay
					.zIndex(999)
			}
			
			// MCP Client Approval Overlay
			if let clientID = viewModel.state.mcpServer.pendingClientID,
			viewModel.state.mcpServer.isApprovalOverlayVisible {
				MCPApprovalOverlayView(clientID: clientID)
					.environmentObject(viewModel.state.mcpServer)
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
					.zIndex(1000)
			}
			
			// Workspace Operation Approval Overlay
			if let request = workspaceApprovalManager.pendingRequest,
				workspaceApprovalManager.isApprovalOverlayVisible {
				WorkspaceApprovalOverlayView(
					approvalManager: workspaceApprovalManager,
					request: request
				)
				.transition(.opacity.combined(with: .scale(scale: 0.95)))
				.zIndex(1001)
			}
		}
	.toolbar { toolbarContent }

		.onAppear {
			appearCounter += 1
			showWorkspaceSwitchOverlay = viewModel.workspaceManager.isWorkspaceSwitchOverlayVisible

			// Evaluate initial route (workspace entry vs main) and auto-onboarding
			viewModel.evaluateInitialRouteIfNeeded()

			// Keep visibility in sync with legacy collapsed flag for first render
			columnVisibility = viewModel.isSidebarCollapsed ? .detailOnly : .all
			// Initialize recommendation wizard view model
			if recommendationWizardViewModel == nil {
				let engine = AutoRecommendationEngine(
					settingsStore: GlobalSettingsStore.shared,
					apiSettingsViewModel: viewModel.apiSettingsViewModel
				)
				recommendationWizardViewModel = RecommendationWizardViewModel(
					engine: engine,
					settingsStore: GlobalSettingsStore.shared,
					workspaceManager: viewModel.workspaceManager,
					windowID: viewModel.state.windowID
				)
			}
			
		}
		.sheet(isPresented: $showWorkspaceSetup) {
			WorkspaceSetupView(
				onClose: { showWorkspaceSetup = false },
				onWorkspaceCreated: { newWs in
					Task {
						await viewModel.workspaceManager.createAndActivateWorkspace(
							name: newWs.name,
							repoPaths: newWs.repoPaths
						) {
							// Do any UI steps before switching
							showWorkspaceSetup = false
						}
						// Auto-apply recommendations for the newly created workspace
						// Use activeWorkspaceID since createAndActivateWorkspace generates a new UUID
						if let wizardVM = recommendationWizardViewModel,
						   let actualWorkspaceID = viewModel.workspaceManager.activeWorkspaceID {
							wizardVM.autoApplyForNewWorkspace(workspaceID: actualWorkspaceID)
						}
					}
				}
			)
			.environmentObject(viewModel.workspaceManager)
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .switchToAIQueryView)
		) { notification in
			if let id = notification.userInfo?["windowID"] as? Int,
				id == viewModel.state.windowID {
				// If sidebar was not already collapsed, mark for auto-restore
				shouldAutoRestoreSidebarAfterAIQuery = (columnVisibility != .detailOnly)
				// Collapse the sidebar
				columnVisibility = .detailOnly
				viewModel.isSidebarCollapsed = true
				// Switch to AIQuery view
				viewModel.currentView = .aiQuery
			}
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .toggleRepoPromptNavigationSidebar)
		) { notification in
			if let id = notification.userInfo?["windowID"] as? Int,
				id == viewModel.state.windowID,
				viewModel.rootRoute == .main,
				viewModel.uiMode == .ide {
				toggleSidebar()
			}
		}
		.onReceive(
			NotificationCenter.default.publisher(
				for: .workspaceSwitchOverlayDidChange,
				object: viewModel.workspaceManager
			)
		) { notification in
			if let isVisible = notification.userInfo?["isVisible"] as? Bool {
				showWorkspaceSwitchOverlay = isVisible
			}
		}
		.modifier(SidebarVisibilitySyncHandler(
			isSidebarCollapsed: viewModel.isSidebarCollapsed,
			currentView: viewModel.currentView,
			columnVisibility: $columnVisibility,
			shouldAutoRestoreSidebarAfterAIQuery: $shouldAutoRestoreSidebarAfterAIQuery,
			onSetSidebarCollapsed: { viewModel.isSidebarCollapsed = $0 }
		))
		.alert("API Key Required", isPresented: $viewModel.showNoAPIKeyAlert) {
			Button("Open Settings") {
				SettingsWindowCoordinator.shared.open(windowState: viewModel.state, selectedTab: .apiGeneral)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Please set your API key in the settings before sending a query to the AI.")
		}
		.workspaceSwitchConfirmation(manager: viewModel.workspaceManager)
		// Create-Preset naming sheet
		.sheet(isPresented: $showCreatePresetSheet) {
			if let ws = viewModel.workspaceManager.activeWorkspace {
				PresetCreationSheet(workspace: ws)
					.environmentObject(viewModel.workspaceManager)
			} else {
				Text("No active workspace")
					.padding()
			}
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .showCreatePresetSheet)
		) { note in
			// Only react if the notification's windowID matches this window
			if let id = note.userInfo?["windowID"] as? Int,
				id == viewModel.state.windowID {
				showCreatePresetSheet = true
			}
		}
		// MCP Status sheet
		.sheet(isPresented: $showMCPStatusSheet) {
			MCPStatusView(server: viewModel.state.mcpServer)
		}
		.modifier(WizardAndMCPNotificationHandler(
			onShowWizard: { viewModel.presentSetupGuide() },
			onShowMCPPopover: { handleShowMCPServerPopover($0) }
		))
		.modifier(SettingsNotificationHandler(
			windowState: viewModel.state,
			legacyShowSettings: $viewModel.showSettings
		))
		// Listen for notifications to show MCP status
		.onReceive(
			NotificationCenter.default.publisher(for: .showMCPStatusWindow)
		) { note in
			if let id = note.userInfo?["windowID"] as? Int,
			id == viewModel.state.windowID {
				showMCPStatusSheet = true
			}
		}
		// Listen for notifications to open recommendation wizard
		.onReceive(
			NotificationCenter.default.publisher(for: .showRecommendationWizard)
		) { note in
			if let id = note.userInfo?["windowID"] as? Int,
			id == viewModel.state.windowID {
				// Refresh wizard state and open popover
				recommendationWizardViewModel?.refresh(navigation: .resetToIntro)
				showRecommendationsPopover = true
			}
		}
		// Close all sheets when a connection approval request comes in
		.onChange(of: viewModel.state.mcpServer.isApprovalOverlayVisible) { _, isVisible in
			if isVisible {
				closeAllSheets()
			}
		}
		// Close all sheets when a workspace approval request comes in
		.onChange(of: workspaceApprovalManager.isApprovalOverlayVisible) { _, isVisible in
			if isVisible {
				closeAllSheets()
			}
		}
		return mainContent
			.environmentObject(viewModel.workspaceManager)
	}
}

// MARK: - Subviews
extension ContentView {
	
	@ViewBuilder
	private var sidebarView: some View {
		FileTreeView(
			windowID: viewModel.state.windowID,
			fileManager: viewModel.fileManager,
			workspaceViewModel: viewModel.workspaceManager,
			searchViewModel: viewModel.searchViewModel,
			onOpenWorkspace: { ws in
				Task {
					_ = await viewModel.workspaceManager.requestWorkspaceSwitch(to: ws)
				}
			},
			onManageWorkspaces: {
				NotificationCenter.default.post(
					name: .showManageWorkspacesTab,
					object: nil,
					userInfo: ["windowID": viewModel.state.windowID])
			}
		)
	}
	
	@ViewBuilder
	private var detailView: some View {
		Group {
			if viewModel.currentView == .aiQuery {
				AIQueryView(
					viewModel: viewModel.aiResponseViewModel,
					promptViewModel: viewModel.promptManager,
					showSettings: $viewModel.showSettings,
					currentView: $viewModel.currentView
				)
			} else {
				TabbedPromptView(
					promptManager: viewModel.promptManager,
					fileManager: viewModel.fileManager,
					aiResponseViewModel: viewModel.aiResponseViewModel,
					diffViewModel: viewModel.diffViewModel,
					chatViewModel: viewModel.chatViewModel,
					apiSettingsViewModel: viewModel.apiSettingsViewModel,
					windowState: viewModel.state,
					currentTab: $viewModel.currentTab,
					showSettings: $viewModel.showSettings,
					currentView: $viewModel.currentView,
					selectFileForPreview: { file in
						viewModel.selectedFileForPreview = file
					}
				)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var workspaceSwitchLoadingOverlay: some View {
		ZStack {
			Color.black
				.opacity(0.16)
				.ignoresSafeArea()

			VStack(spacing: 12) {
				ProgressView()
					.controlSize(.large)
					.tint(.white)

				Text("Switching workspace...")
					.font(.system(size: 13, weight: .medium))
					.foregroundColor(.white)

				Button("Cancel") {
					Task {
						await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
					}
				}
				.buttonStyle(CustomButtonStyle())
			}
			.padding(20)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.transition(.opacity)
	}
	
}

// MARK: - Toolbar Content
extension ContentView {
	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		// Agent/IDE mode toggle
		ToolbarItem(placement: .automatic) {
			AgentModeToggle(mode: viewModel.uiModeBinding)
		}

		// Recommendation wizard button
		ToolbarItem(placement: .automatic) {
			if let wizardVM = recommendationWizardViewModel {
				RecommendationToolbarButtonView(
					viewModel: wizardVM,
					showPopover: $showRecommendationsPopover
				)
			}
		}

		// TOOLBAR POPOVER FIX: Pass bindings to prevent state loss during toolbar re-evaluation
		ToolbarItem(placement: .automatic) {
			MCPServerToggleView(windowState: viewModel.state, showPopover: $showMCPServerPopover)
		}
	}
	
	private func toggleSidebar() {
		withAnimation(.easeInOut(duration: 0.2)) {
			if columnVisibility == .detailOnly {
				columnVisibility = .all
				viewModel.isSidebarCollapsed = false
			} else {
				columnVisibility = .detailOnly
				viewModel.isSidebarCollapsed = true
			}
		}
	}
	
	
	private func handleShowMCPServerPopover(_ note: Notification) {
		if let id = note.userInfo?["windowID"] as? Int,
		id != viewModel.state.windowID {
			return
		}
		showMCPServerPopover = true
	}

	private func closeAllSheets() {
		withAnimation {
			showWorkspaceSetup = false
			showMissingBookmarksSheet = false
			showCreatePresetSheet = false
			showMCPStatusSheet = false
		}
	}

	// Note: Preset keyboard shortcuts are now handled in ContentViewModel
}

// MARK: - Notification Handler Modifier

/// Extracted to reduce type-checker load on ContentView.body
private struct WizardAndMCPNotificationHandler: ViewModifier {
	let onShowWizard: () -> Void
	let onShowMCPPopover: (Notification) -> Void
	
	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .showAgentOnboardingWizard)) { _ in
				onShowWizard()
			}
			.onReceive(NotificationCenter.default.publisher(for: .showMCPServerPopover)) { note in
				onShowMCPPopover(note)
			}
	}
}

/// Extracted to reduce type-checker load on ContentView.body
private struct SettingsNotificationHandler: ViewModifier {
	let windowState: WindowState
	@Binding var legacyShowSettings: Bool

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .showSettingsPopover)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: nil)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showAPISettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .apiGeneral)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showManageWorkspacesTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .manageWorkspaces)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showManagePresetsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .managePresets)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showMCPSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .mcp)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showCLIProvidersTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .cliProviders)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showAgentModeSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .agentMode)
			}
			.modifier(AgentModeDeepLinkNotificationHandler(windowState: windowState))
			.onReceive(NotificationCenter.default.publisher(for: .showModelPresetsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .modelPresets)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showCopyPresetsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .copyPresets)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showChatPresetsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .chatPresets)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showContextBuilderSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .contextBuilder)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcutsSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .keyboardShortcuts)
			}
			.onChange(of: legacyShowSettings) { _, isShowing in
				guard isShowing else { return }
				SettingsWindowCoordinator.shared.open(windowState: windowState)
				legacyShowSettings = false
			}
	}

	private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
		if let sender = note.object as? WindowState {
			return sender === windowState
		}
		if let id = note.userInfo?["windowID"] as? Int {
			return id == windowState.windowID
		}
		let target = WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
			?? WindowStatesManager.shared.latestWindowState
		return target === windowState
	}

	private func openSettings(tab: SettingsTab?) {
		SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: tab)
	}
}

/// Handles the newer Agent-Mode sidebar deep-link notifications
/// (Agent Models / Agent Permissions / Workspace Approvals) as a separate
/// modifier so the parent `SettingsNotificationHandler` stays small enough
/// for the Swift type-checker. Keeps the window-scoping identical to the
/// parent handler — only routes to a different settings tab.
///
/// SEARCH-HELPER: AgentModeDeepLinkNotificationHandler, Agent Mode deep link,
/// Models settings tab handler, Permissions settings tab handler
private struct AgentModeDeepLinkNotificationHandler: ViewModifier {
	let windowState: WindowState

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .showAgentModelsSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .agentModels)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showAgentPermissionsSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .agentPermissions)
			}
			.onReceive(NotificationCenter.default.publisher(for: .showWorkspaceApprovalsSettingsTab)) { note in
				guard noteTargetsCurrentWindow(note) else { return }
				openSettings(tab: .permissions)
			}
	}

	private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
		if let sender = note.object as? WindowState {
			return sender === windowState
		}
		if let id = note.userInfo?["windowID"] as? Int {
			return id == windowState.windowID
		}
		let target = WindowStatesManager.shared.allWindows.first(where: { $0.isCurrentlyFocused })
			?? WindowStatesManager.shared.latestWindowState
		return target === windowState
	}

	private func openSettings(tab: SettingsTab?) {
		SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: tab)
	}
}

/// Keeps split-view sidebar state synchronized with shared view-model state.
private struct SidebarVisibilitySyncHandler: ViewModifier {
	let isSidebarCollapsed: Bool
	let currentView: ViewType
	@Binding var columnVisibility: NavigationSplitViewVisibility
	@Binding var shouldAutoRestoreSidebarAfterAIQuery: Bool
	let onSetSidebarCollapsed: (Bool) -> Void

	func body(content: Content) -> some View {
		content
			.onChange(of: isSidebarCollapsed) { _, isCollapsed in
				columnVisibility = isCollapsed ? .detailOnly : .all
			}
			.onChange(of: currentView) { oldValue, newValue in
				if oldValue == .aiQuery, newValue != .aiQuery, shouldAutoRestoreSidebarAfterAIQuery {
					columnVisibility = .all
					onSetSidebarCollapsed(false)
					shouldAutoRestoreSidebarAfterAIQuery = false
				}
			}
	}
}

// MARK: - AgentModeToggle
private struct AgentModeToggle: View {
	@Binding var mode: WindowUIMode

	var body: some View {
		Picker("", selection: $mode) {
			Text("Agent")
				.tag(WindowUIMode.agent)
			Text("IDE")
				.tag(WindowUIMode.ide)
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.frame(width: 110)
		.help(mode == .ide ? "Switch to Agent mode" : "Switch to IDE mode")
	}
}
