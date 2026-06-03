import SwiftUI
import Combine

// MARK: - App Root Route

/// Top-level routing: workspace entry flow vs main app content.
enum AppRootRoute: Equatable {
	/// Full-window workspace chooser + optional setup guide.
	case workspaceEntry
	/// Normal app content (IDE or Agent mode).
	case main
}

/// Tabs within the workspace entry flow.
enum WorkspaceEntryTab: Equatable {
	case workspaces
	case setupGuide
}

// MARK: - ContentViewModel
@MainActor
class ContentViewModel: ObservableObject {
	@Published var currentView: ViewType = .fileManager
	@Published var showSettings = false
	@Published var currentTab: PromptTab = .compose
	@Published var showNoAPIKeyAlert = false
	@Published var selectedFileForPreview: FileViewModel?
	@Published var showFilePreview = false
	@Published var isWindowFocused: Bool = false
	
	/// Current UI mode (IDE vs Agent) - proxied from WindowState
	@Published var uiMode: WindowUIMode = .ide
	
	// App-level routing
	@Published var rootRoute: AppRootRoute = .main
	@Published var workspaceEntryTab: WorkspaceEntryTab = .workspaces
	@Published var onboardingViewModel: AgentOnboardingWizardViewModel?
	
	// UI layout state
	@Published var splitPosition: Double
	@Published var isSidebarCollapsed: Bool
	
	// Using Combine for notification handling
	private var cancellables = Set<AnyCancellable>()
	
	// Instead of storing each manager individually, store a reference to the whole window's state.
	let state: WindowState
	
	// Shortcut properties
	var fileManager: RepoFileManagerViewModel { state.fileManager }
	var promptManager: PromptViewModel { state.promptManager }
	var aiResponseViewModel: AIResponseViewModel { state.aiResponseViewModel }
	var diffViewModel: DiffViewModel { state.diffViewModel }
	var chatViewModel: ChatViewModel { state.chatViewModel }
	var apiSettingsViewModel: APISettingsViewModel { state.apiSettingsViewModel }
	var workspaceManager: WorkspaceManagerViewModel { state.workspaceManager }
	var searchViewModel: SearchFileTreeViewModel { state.searchViewModel }
	
	init(state: WindowState) {
		self.state = state

		// Default UI layout - must be set before using `self`
		self.splitPosition = 0.3
		self.isSidebarCollapsed = false

		self.state.contentViewModel = self

		// Sync workspace changes to drive routing
		state.workspaceManager.$activeWorkspaceID
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.syncRouteWithWorkspaceState()
			}
			.store(in: &cancellables)

		// Mirror focus state from WindowState (single source of truth).
		self.isWindowFocused = state.isCurrentlyFocused
		state.$isCurrentlyFocused
			.removeDuplicates()
			.receive(on: RunLoop.main)
			.sink { [weak self] focused in
				self?.isWindowFocused = focused
			}
			.store(in: &cancellables)
		
		// Sync uiMode from WindowState
		self.uiMode = state.uiMode
		state.$uiMode
			.removeDuplicates()
			.receive(on: RunLoop.main)
			.sink { [weak self] mode in
				self?.uiMode = mode
			}
			.store(in: &cancellables)
	}
	
	/// Binding for UI mode toggle that syncs back to WindowState
	var uiModeBinding: Binding<WindowUIMode> {
		Binding(
			get: { self.uiMode },
			set: { [weak self] newValue in
				guard let self else { return }
				self.uiMode = newValue
				self.state.uiMode = newValue
			}
		)
	}
	
	// MARK: - Route Management
	
	/// Whether the active workspace is the system fallback (i.e. no real workspace selected).
	var isInSystemFallback: Bool {
		guard let ws = state.workspaceManager.activeWorkspace else { return true }
		return ws.isSystemWorkspace
	}
	
	/// Called on first appear to determine initial route and optionally show onboarding.
	func evaluateInitialRouteIfNeeded() {
		if AppLaunchConfiguration.current.forcedRootRoute == .main {
			rootRoute = .main
			return
		}
		if isInSystemFallback {
			rootRoute = .workspaceEntry
			
			// Check if onboarding should auto-show
			let shouldShow = AgentOnboardingGate.shouldShow()
			if shouldShow && AgentOnboardingPresentationCoordinator.shared.claimPresentationSlot() {
				ensureOnboardingViewModel()
				workspaceEntryTab = .setupGuide
			} else {
				workspaceEntryTab = .workspaces
			}
		} else {
			rootRoute = .main
		}
	}
	
	/// Keeps route in sync when workspace changes (e.g. exit to fallback, or open workspace).
	func syncRouteWithWorkspaceState() {
		if AppLaunchConfiguration.current.forcedRootRoute == .main {
			rootRoute = .main
			return
		}
		if isInSystemFallback {
			if rootRoute != .workspaceEntry {
				rootRoute = .workspaceEntry
				workspaceEntryTab = .workspaces
			}
		} else {
			if rootRoute == .workspaceEntry {
				rootRoute = .main
			}
		}
	}
	
	/// Shows the workspace entry flow with the setup guide tab (user-invoked from Help menu / notification).
	func presentSetupGuide() {
		ensureOnboardingViewModel()
		onboardingViewModel?.resetToStart()
		workspaceEntryTab = .setupGuide
		rootRoute = .workspaceEntry
	}
	
	/// Dismiss workspace entry if the user explicitly invoked it (not forced by system fallback).
	func dismissWorkspaceEntryIfAllowed() {
		if AppLaunchConfiguration.current.forcedRootRoute == .main {
			rootRoute = .main
			return
		}
		if !isInSystemFallback {
			rootRoute = .main
		}
	}
	
	/// Lazily creates the onboarding view model if needed.
	func ensureOnboardingViewModel() {
		guard onboardingViewModel == nil else { return }
		let engine = AutoRecommendationEngine(
			settingsStore: GlobalSettingsStore.shared,
			apiSettingsViewModel: apiSettingsViewModel
		)
		onboardingViewModel = AgentOnboardingWizardViewModel(
			engine: engine,
			apiSettingsViewModel: apiSettingsViewModel
		)
	}
}
