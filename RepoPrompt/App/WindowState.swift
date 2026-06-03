import SwiftUI
import Combine
import AppKit
import Foundation

enum WindowKind: String, Codable, Sendable {
	case standard
	case discoverAgent
}

/// UI mode for the main window content area
enum WindowUIMode: String, Codable, Sendable {
	case ide
	case agent
}

enum WindowInitialUIModeResolver {
	static func resolve(
		forcedMode: WindowUIMode?,
		globalStoredModeRawValue: String?,
		deferGlobalFallbackForPendingRestore: Bool
	) -> WindowUIMode {
		if let forcedMode {
			return forcedMode
		}
		if deferGlobalFallbackForPendingRestore {
			return .ide
		}
		if let globalStoredModeRawValue,
		   let mode = WindowUIMode(rawValue: globalStoredModeRawValue) {
			return mode
		}
		return .ide
	}
}

enum WindowTitleFormatter {
	static func compose(
		workspaceTitle: String,
		uiMode: WindowUIMode,
		agentSessionTitle: String?,
		duplicateWorkspaceTitle: String? = nil
	) -> String {
		guard uiMode == .agent else { return workspaceTitle }

		let trimmedSessionTitle = agentSessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !trimmedSessionTitle.isEmpty else { return workspaceTitle }

		let duplicateTitles = [workspaceTitle, duplicateWorkspaceTitle]
			.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
		guard !duplicateTitles.contains(where: { trimmedSessionTitle.caseInsensitiveCompare($0) == .orderedSame }) else {
			return workspaceTitle
		}

		return "\(trimmedSessionTitle) — \(workspaceTitle)"
	}
}

enum PendingInteractionSurface {
	case contextualQuestion
	case agentQuestion
}

/// Represents a command from CLI or URL
struct AppCommand {
	let workspaceName: String?
	let fileList: [String]
	let promptText: String?
	let folderPath: String?
	
	/// NEW: prompt that should be saved to `PromptViewModel`
	let newPrompt: (title: String, content: String)?
	
	/// When true, attempt to focus an existing window for the given workspace/folder if already open.
	let focus: Bool?
	
	/// When true, do not persist this workspace to disk/index (only keep in memory).
	/// If set, you can treat this as "ephemeral" usage.
	let ephemeral: Bool?
	
	/// When false, skip saving changes to disk/index. If nil or true, persist by default.
	let persist: Bool?
	
	var isEmpty: Bool {
		return workspaceName == nil
			&& fileList.isEmpty
			&& promptText == nil
			&& folderPath == nil
			&& newPrompt == nil        // <- include new field
			&& focus == nil
			&& ephemeral == nil
			&& persist == nil
	}
}

/// Holds all of the per-window managers/services.
/// Each new window in the app gets a fresh instance of WindowState.
@MainActor
class WindowState: ObservableObject {
	
	// MARK: - Shared Services
	
	/// Single shared MCP service instance across all windows
	private static let sharedMCPService = MCPService()
	// MARK: - Window identification
	
	static private(set) var windowCounter = 0
	let windowID: Int
	
	// Add this AppStorage property
	@AppStorage("mcpAutoStart") private var autoStartServer = false

	@Published var kind: WindowKind = .standard
	private var suppressGlobalUIModePersistence = false
	
	/// Current UI mode (IDE vs Agent). Captured per window session; `windowUIMode` is only a legacy/default fallback.
	@Published var uiMode: WindowUIMode = .ide {
		didSet {
			if !suppressGlobalUIModePersistence,
				!AppLaunchConfiguration.current.suppressesWindowModePersistence {
				UserDefaults.standard.set(uiMode.rawValue, forKey: "windowUIMode")
				(windowStatesManager ?? WindowStatesManager.shared).persistWindowSession(reason: "uiModeChanged")
			}
			if let window = nsWindow {
				configureWindowChrome(for: window)
			}
			requestWindowTitleUpdate(reason: .uiModeChanged)
		}
	}
	
	// MARK: - Focus Tracking
	@Published var isCurrentlyFocused: Bool = false

	/// Per-window teardown guard. Not @Published (we don't want SwiftUI updates during teardown).
	private(set) var isClosing: Bool = false

	private var focusCancellables = Set<AnyCancellable>()
	private weak var focusObservedWindow: NSWindow?
	
	/// Holds Combine subscriptions local to this window state
	private var cancellables = Set<AnyCancellable>()
	
	/// Called whenever `isCurrentlyFocused` changes.
	var onFocusChanged: ((Bool) -> Void)?
	
	// MARK: - Per-Window View Models

	let fileManager: RepoFileManagerViewModel
	let settingsManager: WindowSettingsManager
	let promptManager: PromptViewModel
	let aiResponseViewModel: AIResponseViewModel
	let diffViewModel: DiffViewModel
	let chatViewModel: ChatViewModel
	let apiSettingsViewModel: APISettingsViewModel
	let searchViewModel: SearchFileTreeViewModel
	let discoverAgentViewModel: DiscoverAgentViewModel
	let agentModeViewModel: AgentModeViewModel
	#if DEBUG
	let agentChatStressHarness: AgentChatStressHarness?
	#endif

	// MARK: - MCP Server (one per window)
	let mcpServer: MCPServerViewModel
	let closeCoordinator: WindowCloseCoordinator
	
	// MARK: - Services and Utilities
	let keyManager: KeyManager
	let aiQueriesService: AIQueriesService
	let diffParser: DiffParser
	let chatDataService: ChatDataService
	
	// MARK: - Possibly shared references
	let workspaceManager: WorkspaceManagerViewModel
	weak var windowStatesManager: WindowStatesManager?
	weak var contentViewModel: ContentViewModel?
	
	/// Reference to the NSWindow this state is associated with
	weak var nsWindow: NSWindow?
	private var windowDelegateProxy: InterceptingWindowDelegateProxy?
	
	// MARK: - Agent Mode Titlebar Accessory
	
	/// Titlebar accessory controller for Agent mode ("New Session" button near traffic lights)
	private weak var agentTitlebarAccessory: AgentModeTitlebarAccessoryViewController?
	/// Whether Agent mode has requested the titlebar accessory be visible
	private var wantsAgentTitlebarAccessory: Bool = false
	/// Action to call when the "New Session" button is tapped
	private var agentNewSessionAction: (() -> Void)?
	
	/// The sticky instance number assigned for this window's current workspace (monotonically increasing per workspace).
	/// Nil when no workspace is active yet.
	@Published var workspaceInstanceNumber: Int? = nil
	
	/// Convenience: the workspace name with an instance suffix " (N)" when N ≥ 2,
	/// except for the default/system workspace which always shows "Repo Prompt".
	var workspaceDisplayName: String {
		guard let ws = workspaceManager.activeWorkspace else {
			return "Repo Prompt"
		}
		
		if ws.isSystemWorkspace {
			return "Repo Prompt"
		}
		
		let base = ws.name
		if let n = workspaceInstanceNumber, n >= 2 {
			return "\(base) (\(n))"
		}
		return base
	}

	// Cache to survive transient activeWorkspace == nil. This may include Agent session context.
	private var lastKnownResolvedTitle: String = "Repo Prompt"
	private var lastAppliedWindowTitle: String? = nil

	private func resolvedWindowTitle() -> String {
		guard let ws = workspaceManager.activeWorkspace else {
			// If we expect a workspace but it is temporarily unresolved, do not stomp to default.
			if workspaceManager.activeWorkspaceID != nil {
				return lastKnownResolvedTitle
			}

			return "Repo Prompt"
		}

		let workspaceTitle = resolvedWorkspaceWindowTitle(for: ws)
		let resolvedTitle = WindowTitleFormatter.compose(
			workspaceTitle: workspaceTitle,
			uiMode: uiMode,
			agentSessionTitle: resolvedAgentSessionTitleForWindowTitle(activeWorkspace: ws),
			duplicateWorkspaceTitle: ws.isSystemWorkspace ? "Repo Prompt" : ws.name
		)
		lastKnownResolvedTitle = resolvedTitle
		return resolvedTitle
	}

	private func resolvedWorkspaceWindowTitle(for workspace: WorkspaceModel) -> String {
		if workspace.isSystemWorkspace {
			return "Repo Prompt"
		}

		let base = workspace.name
		if let n = workspaceInstanceNumber, n >= 2 {
			return "\(base) (\(n))"
		}
		return base
	}

	private func resolvedAgentSessionTitleForWindowTitle(activeWorkspace: WorkspaceModel) -> String? {
		guard uiMode == .agent,
			!activeWorkspace.isSystemWorkspace,
			promptManager.activeComposeTabID != nil else {
			return nil
		}

		let rawTitle = promptManager.activeComposeTabID.flatMap { workspaceManager.composeTabName(with: $0) }
		return AgentSessionRestoreSupport.normalizedSessionTitle(rawTitle)
	}

	enum WindowTitleUpdateReason {
		case windowAttached
		case workspaceChanged
		case focusChanged
		case appBecameActive
		case uiModeChanged
		case activeComposeTabChanged
		case agentSessionNameChanged
		case explicit
		case unspecified
	}
	
	// Command queue to store all pending commands
	private var commandQueue: [AppCommand] = []

	/// Lazily scheduled task to coalesce window title updates outside of mutation scopes.
	private var pendingWindowTitleUpdateTask: Task<Void, Never>? = nil
	/// Lazily scheduled task to coalesce focus updates outside of mutation scopes.
	private var pendingFocusUpdateTask: Task<Void, Never>? = nil
	/// Lazily scheduled task to coalesce focus side-effects outside of mutation scopes.
	private var pendingFocusSideEffectsTask: Task<Void, Never>? = nil

	private var shouldSuppressObservationSideEffects: Bool {
		// Avoid SwiftUI observation churn during teardown/termination.
		isClosing || WindowStatesManager.shared.isTerminating
	}

	func beginClose() {
		guard !isClosing else { return }
		isClosing = true

		let manager = windowStatesManager ?? WindowStatesManager.shared
		if !manager.isTerminating {
			manager.markWindowAsExplicitlyClosing(windowID: windowID)
		}
		closeCoordinator.beginClose()
		onFocusChanged = nil
		removeFocusObservers()
		pendingWindowTitleUpdateTask?.cancel()
		pendingWindowTitleUpdateTask = nil
		pendingFocusUpdateTask?.cancel()
		pendingFocusUpdateTask = nil
		pendingFocusSideEffectsTask?.cancel()
		pendingFocusSideEffectsTask = nil
		detachTitlebarAccessoryControllers(from: nsWindow)
		clearTitlebarAccessoryRequestsForClose()
	}
	
	private var pendingRestoreEntry: WindowSessionEntry?
	private var deferredGlobalUIModeFallbackOnInit = false
	private(set) var claimedInitialAgentSystemWorkspaceRefreshDeferralID: UUID?
	private(set) var claimedInitialAgentSystemWorkspaceRefreshDeferralWaiterID: UUID?
	
	// MARK: - Initialization
	
	init() {
		#if DEBUG
		let initStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		let initialGlobalUIMode = UserDefaults.standard.string(forKey: "windowUIMode") ?? "nil"
		let forcedInitialUIMode = AppLaunchConfiguration.current.forcedWindowUIMode?.rawValue ?? "nil"
		var workspaceManagerInitDurationMS: Double?
		#endif
		// Assign a unique window ID
		WindowState.windowCounter += 1
		self.windowID = WindowState.windowCounter
		let manager = WindowStatesManager.shared
		
		// Load persisted UI mode
		let savedMode = UserDefaults.standard.string(forKey: "windowUIMode")
		let deferredGlobalFallbackForRestore = manager.shouldDeferGlobalUIModeFallbackForNewWindow
		let claimedInitialAgentSystemWorkspaceRefreshDeferral = manager.claimInitialAgentSystemWorkspaceRefreshDeferralForNewWindow()
		let deferredInitialAgentSystemWorkspaceRefresh = claimedInitialAgentSystemWorkspaceRefreshDeferral != nil
		self.claimedInitialAgentSystemWorkspaceRefreshDeferralID = claimedInitialAgentSystemWorkspaceRefreshDeferral?.id
		self.claimedInitialAgentSystemWorkspaceRefreshDeferralWaiterID = claimedInitialAgentSystemWorkspaceRefreshDeferral?.waiterID
		self.deferredGlobalUIModeFallbackOnInit = deferredGlobalFallbackForRestore
		self.uiMode = WindowInitialUIModeResolver.resolve(
			forcedMode: AppLaunchConfiguration.current.forcedWindowUIMode,
			globalStoredModeRawValue: savedMode,
			deferGlobalFallbackForPendingRestore: deferredGlobalFallbackForRestore
		)

		// ️⃣ Connect to the global WindowStatesManager singleton
		self.windowStatesManager = manager
		
		// 1) File manager
		self.fileManager = RepoFileManagerViewModel()

		// 2) AI response + queries
		self.aiResponseViewModel = AIResponseViewModel(fileManager: self.fileManager)
		self.keyManager = KeyManager()
		self.aiQueriesService = AIQueriesService(viewModel: self.aiResponseViewModel, keyManager: self.keyManager)
		
		// 3) API Settings
		self.apiSettingsViewModel = APISettingsViewModel(aiQueriesService: self.aiQueriesService, keyManager: self.keyManager)
		
		// 4) Diff
		self.diffParser = DiffParser(fileManager: self.fileManager)
		self.diffViewModel = DiffViewModel(
			diffParser: self.diffParser,
			fileManager: self.fileManager,
			aiResponseViewModel: self.aiResponseViewModel
		)

		// 5) Settings Manager (per-window overlay)
		self.settingsManager = WindowSettingsManager(windowID: self.windowID)

		// 6) Prompt
		self.promptManager = PromptViewModel(
			fileManager: self.fileManager,
			diffViewModel: self.diffViewModel,
			aiQueriesService: self.aiQueriesService,
			aiResponseViewModel: self.aiResponseViewModel,
			apiSettingsViewModel: self.apiSettingsViewModel,
			windowID: self.windowID,
			settingsManager: self.settingsManager
		)
		
		// 7) Create the workspace manager
		#if DEBUG
		let workspaceManagerInitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		self.workspaceManager = WorkspaceManagerViewModel(
			fileManager: self.fileManager,
			promptViewModel: self.promptManager
		)
		#if DEBUG
		if let workspaceManagerInitStartMS {
			workspaceManagerInitDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: workspaceManagerInitStartMS)
		}
		#endif

		// 8) Search
		self.searchViewModel = SearchFileTreeViewModel()
		self.searchViewModel.setFileManager(self.fileManager)
		self.searchViewModel.setWorkspaceManager(self.workspaceManager)

		// 10) Chat
		self.chatDataService = ChatDataService()
		self.chatViewModel = ChatViewModel(
			aiQueriesService: self.aiQueriesService,
			aiResponseViewModel: self.aiResponseViewModel,
			diffViewModel: self.diffViewModel,
			promptViewModel: self.promptManager,
			workspaceManager: self.workspaceManager,
			chatData: self.chatDataService
		)

		// 11) MCP server (one listener app-wide, this window may be owner)
		let applyEditsApprovalStore = ApplyEditsApprovalStore.shared
		self.mcpServer = MCPServerViewModel(
			service:     Self.sharedMCPService,
			fileManager: self.fileManager,
			searchVM:    self.searchViewModel,
			promptVM:    self.promptManager,
			chatVM:      self.chatViewModel,
			workspaceManager: self.workspaceManager,
			windowID:    self.windowID,
			applyEditsApprovalStore: applyEditsApprovalStore
		)
		self.closeCoordinator = WindowCloseCoordinator()

		// 12) Discover agent (needs mcpServer reference)
		self.discoverAgentViewModel = DiscoverAgentViewModel(
			fileManager: self.fileManager,
			promptManager: self.promptManager,
			workspaceManager: self.workspaceManager,
			mcpServer: self.mcpServer,
			chatViewModel: self.chatViewModel
		)

		// 13) Agent mode (for minimal agent UI)
		self.agentModeViewModel = AgentModeViewModel(
			windowID: self.windowID,
			promptManager: self.promptManager,
			workspaceManager: self.workspaceManager,
			mcpServer: self.mcpServer,
			chatViewModel: self.chatViewModel,
			applyEditsApprovalStore: applyEditsApprovalStore
		)
		if deferredInitialAgentSystemWorkspaceRefresh {
			self.agentModeViewModel.deferInitialSystemWorkspaceSessionListRefresh(reason: "programmaticNewWindowWorkspaceSwitch")
		}
		#if DEBUG
		if let stressConfiguration = AppLaunchConfiguration.current.agentChatStress {
			let agentModeViewModel = self.agentModeViewModel
			let promptManager = self.promptManager
			let windowID = self.windowID
			self.agentChatStressHarness = AgentChatStressHarness(
				configuration: stressConfiguration,
				agentModeViewModel: agentModeViewModel,
				promptManager: promptManager,
				workspaceManager: self.workspaceManager,
				windowID: windowID
			)
		} else {
			self.agentChatStressHarness = nil
		}
		#endif

		// 14) Register workspace switch session providers
		self.workspaceManager.registerSwitchSessionProvider(
			ChatWorkspaceSwitchSessionProvider(
				workspaceManager: self.workspaceManager,
				chatViewModel: self.chatViewModel
			)
		)
		self.workspaceManager.registerSwitchSessionProvider(
			ContextAndDiscoverWorkspaceSwitchSessionProvider(
				discoverAgentViewModel: self.discoverAgentViewModel
			)
		)
		self.workspaceManager.registerSwitchSessionProvider(
			AgentModeWorkspaceSwitchSessionProvider(
				agentModeViewModel: self.agentModeViewModel
			)
		)

		// Set up additional actions
		self.setupMergeAction()
		self.setupSendPromptAction()
		self.setupProEditBridge()

		// Set up workspace switch listener to sync settings and validate prompts
		self.workspaceManager.addWorkspaceDidSwitchListener(label: "windowState") { [weak self] _ in
			guard let self = self else { return }
			self.promptManager.syncSettingsFromSettingsManager()
			
			// Validate Claude Code commands for workspace root folders (if previously installed)
			let roots = self.fileManager.rootFolders.map(\.fullPath)
			Task.detached(priority: .utility) {
				await MCPPromptValidationService.shared.validateClaudeCommandsForWorkspaceRoots(roots)
			}
		}
		
		// Process any queued commands once the workspace is initialized
		self.workspaceManager.onceInitialized { [weak self] in
			guard let self = self else { return }
			Task {
				await self.applyStressWorkspaceBootstrapIfNeeded()
				self.applyPendingRestoreEntryIfPossible()
				await self.processCommands()
			}
		}

		// Set up MCP auto-start if enabled
		setupMCPAutoStartIfNeeded()
		
		// Subscribe to workspace instance number changes to update title
		$workspaceInstanceNumber
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .workspaceChanged)
			}
			.store(in: &cancellables)
		
		// Subscribe to workspace name changes to update title
		NotificationCenter.default.publisher(for: .workspaceListDidChange)
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .workspaceChanged)
			}
			.store(in: &cancellables)

		// Re-assert title when the active workspace identity changes (including nil -> non-nil).
		workspaceManager.$activeWorkspaceID
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .workspaceChanged)
			}
			.store(in: &cancellables)

		// Also refresh title when the workspaces array mutates (e.g., rename or disk reload)
		// without a formal "switch". Resolved title handles transient nil states safely.
		workspaceManager.$workspaces
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .workspaceChanged)
			}
			.store(in: &cancellables)

		// Agent session identity in the title follows the active compose tab and its display name.
		promptManager.$activeComposeTabID
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .activeComposeTabChanged)
			}
			.store(in: &cancellables)

		Publishers.CombineLatest(promptManager.$activeComposeTabID, promptManager.$currentComposeTabs)
			.map { activeTabID, tabs -> String? in
				guard let activeTabID else { return nil }
				return tabs.first(where: { $0.id == activeTabID })?.name
			}
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.requestWindowTitleUpdate(reason: .agentSessionNameChanged)
			}
			.store(in: &cancellables)

		closeCoordinator.windowState = self
		#if DEBUG
		if let initStartMS {
			let workspaceManagerDuration = workspaceManagerInitDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
			WorkspaceRestorePerfLog.log(
				"window.init windowID=\(windowID) initialMode=\(uiMode.rawValue) globalUIMode=\(initialGlobalUIMode) forcedUIMode=\(forcedInitialUIMode) deferredGlobalFallbackForRestore=\(deferredGlobalFallbackForRestore) deferredInitialAgentSystemWorkspaceRefresh=\(deferredInitialAgentSystemWorkspaceRefresh) claimedInitialAgentDeferralID=\(claimedInitialAgentSystemWorkspaceRefreshDeferralID?.uuidString.prefix(8).description ?? "nil") claimedInitialAgentDeferralWaiterID=\(claimedInitialAgentSystemWorkspaceRefreshDeferralWaiterID?.uuidString.prefix(8).description ?? "nil") workspaceManagerInit=\(workspaceManagerDuration) total=\(WorkspaceRestorePerfLog.formatElapsedMS(since: initStartMS))"
			)
		}
		#endif
	}
	
	// MARK: - Setup Actions
	
	@MainActor
	private func applyStressWorkspaceBootstrapIfNeeded() async {
		#if DEBUG
		guard let configuration = AppLaunchConfiguration.current.agentChatStress,
			let workspaceName = configuration.workspaceName else {
			return
		}

		if let existingWorkspace = workspaceManager.workspaces.first(where: { $0.name == workspaceName }) {
			guard workspaceManager.activeWorkspaceID != existingWorkspace.id else { return }
			_ = await workspaceManager.requestWorkspaceSwitch(to: existingWorkspace, saveState: false)
			return
		}

		guard configuration.createsWorkspaceIfNeeded,
			!configuration.workspaceRootPaths.isEmpty else {
			return
		}

		let createdWorkspace = workspaceManager.createWorkspace(
			name: workspaceName,
			repoPaths: configuration.workspaceRootPaths,
			ephemeral: true
		)
		_ = await workspaceManager.requestWorkspaceSwitch(to: createdWorkspace, saveState: false)
		#endif
	}

	private func setupMergeAction() {
		self.chatViewModel.setMergeAction { [weak self] in
			self?.promptManager.performChatMergeAction()
		}
		self.diffViewModel.setMergeAction { [weak self] in
			self?.promptManager.performChatMergeAction()
		}
	}
	
	private func setupProEditBridge() {
		self.diffViewModel.proEditAction = { [weak self] instructions, xml in
			guard let self = self else { return }
			self.chatViewModel.startProEditSession(userInstructions: instructions,
												assistantXML: xml)
			// Switch UI to Chat tab
			NotificationCenter.default.post(
				name: .switchToChatView,
				object: nil,
				userInfo: ["windowID": self.windowID])
		}
	}
	
	private func setupMCPAutoStartIfNeeded() {
		guard autoStartServer else { return }
		Task { [weak self] in
			await self?.mcpServer.startServer()
		}
	}
	
	private func setupSendPromptAction() {
		self.chatViewModel.setupSendPromptAction()
	}
	
	// MARK: - Window Management

	/// Attaches the NSWindow to this state and updates the title.
	/// Uses deferred title update to avoid triggering layout during window lifecycle events
	/// (REPOPROMPT-1K4 fix).
	func attachWindow(_ window: NSWindow?) {
		// Detach path (always do the cleanup even if both are nil)
		if window == nil {
			let oldWindow = nsWindow
			detachTitlebarAccessoryControllers(from: oldWindow)
			self.nsWindow = nil
			removeFocusObservers()
			pendingWindowTitleUpdateTask?.cancel()
			pendingWindowTitleUpdateTask = nil
			pendingFocusUpdateTask?.cancel()
			pendingFocusUpdateTask = nil
			scheduleFocusUpdate(false)
			return
		}
		guard let window else { return }

		if nsWindow === window {
			configureWindowChrome(for: window)
			ensureWindowDelegateProxy(for: window)
			scheduleFocusUpdate(from: window)
			requestWindowTitleUpdate(reason: .windowAttached)
			applyAgentTitlebarAccessoryIfPossible()
			return
		}

		if let oldWindow = nsWindow, oldWindow !== window {
			detachTitlebarAccessoryControllers(from: oldWindow)
		}
		self.nsWindow = window
		if AppLaunchConfiguration.current.isUITestSession {
			DispatchQueue.main.async {
				NSApp.activate(ignoringOtherApps: true)
				window.makeKeyAndOrderFront(nil)
			}
		}
		configureWindowChrome(for: window)
		installFocusObservers(for: window)
		scheduleFocusUpdate(from: window)
		ensureWindowDelegateProxy(for: window)
		// Use deferred update to avoid recursive layout issues
		requestWindowTitleUpdate(reason: .windowAttached)
		// Install Agent mode titlebar accessory if requested before window was attached
		applyAgentTitlebarAccessoryIfPossible()
	}

	private func configureWindowChrome(for window: NSWindow) {
		// Keep titlebar visually continuous with content (no horizontal separator).
		window.toolbar?.showsBaselineSeparator = false
		// SwiftUI can recreate toolbar chrome during mode switches; re-apply on next runloop.
		DispatchQueue.main.async { [weak window] in
			window?.toolbar?.showsBaselineSeparator = false
		}
	}

	private func ensureWindowDelegateProxy(for window: NSWindow) {
		if let proxy = windowDelegateProxy {
			if window.delegate !== proxy {
				proxy.forwardedDelegate = window.delegate
				window.delegate = proxy
			}
		} else {
			let proxy = InterceptingWindowDelegateProxy(windowState: self, forwardedDelegate: window.delegate)
			windowDelegateProxy = proxy
			window.delegate = proxy
		}
	}

	private func installFocusObservers(for window: NSWindow) {
		guard focusObservedWindow !== window else { return }
		removeFocusObservers()
		focusObservedWindow = window

		let nc = NotificationCenter.default

		nc.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				guard let self else { return }
				let appIsActive = NSApplication.shared.isActive
				self.scheduleFocusUpdate(appIsActive)
			}
			.store(in: &focusCancellables)

		nc.publisher(for: NSWindow.didResignKeyNotification, object: window)
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.scheduleFocusUpdate(false)
			}
			.store(in: &focusCancellables)

		nc.publisher(for: NSApplication.didBecomeActiveNotification)
			.receive(on: RunLoop.main)
			.sink { [weak self, weak window] _ in
				guard let self, let window else { return }
				self.scheduleFocusUpdate(window.isKeyWindow)
			}
			.store(in: &focusCancellables)

		nc.publisher(for: NSApplication.didResignActiveNotification)
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.scheduleFocusUpdate(false)
			}
			.store(in: &focusCancellables)
	}

	private func removeFocusObservers() {
		focusCancellables.removeAll()
		focusObservedWindow = nil
	}

	private func setFocused(_ focused: Bool) {
		guard !shouldSuppressObservationSideEffects else { return }
		guard isCurrentlyFocused != focused else { return }
		isCurrentlyFocused = focused
		fileManager.setWindowFocused(focused)
		scheduleFocusSideEffects(focused)
	}

	private func scheduleFocusUpdate(from window: NSWindow) {
		let focused = NSApplication.shared.isActive && window.isKeyWindow
		scheduleFocusUpdate(focused)
	}

	private func scheduleFocusUpdate(_ focused: Bool) {
		guard !shouldSuppressObservationSideEffects else { return }
		pendingFocusUpdateTask?.cancel()
		pendingFocusUpdateTask = Task { [weak self] in
			guard let self else { return }
			await Task.yield()
			guard !self.shouldSuppressObservationSideEffects else { return }
			self.applyFocus(focused)
		}
	}

	private func scheduleFocusSideEffects(_ focused: Bool) {
		guard !shouldSuppressObservationSideEffects else { return }
		pendingFocusSideEffectsTask?.cancel()
		pendingFocusSideEffectsTask = Task { [weak self] in
			guard let self else { return }
			await Task.yield()
			guard !self.shouldSuppressObservationSideEffects else { return }
			guard self.isCurrentlyFocused == focused else { return }
			self.onFocusChanged?(focused)
		}
	}

	@MainActor
	private func applyFocus(_ focused: Bool) {
		setFocused(focused)
	}

	/// Safe to call from WindowAccessor notifications; doesn't mutate SwiftUI state.
	private func reassertWindowTitle() {
		guard !shouldSuppressObservationSideEffects else { return }
		applyWindowTitleIfNeeded(resolvedWindowTitle())
	}

	@MainActor
	private func applyWindowTitleIfNeeded(_ title: String) {
		guard let window = nsWindow else { return }
		if window.title == title && lastAppliedWindowTitle == title {
			return
		}
		window.title = title
		lastAppliedWindowTitle = title
	}

	func makeCloseImpactSnapshot() -> WindowCloseImpactSnapshot {
		let manager = windowStatesManager ?? WindowStatesManager.shared
		let allWindows = manager.allWindows
		let mcpEnabledWindowIDs = Set(manager.mcpEnabledWindowIDs())
		let activityItems = workspaceManager.activeSessionSnapshot().items.map {
			WindowCloseActivityItem(
				id: $0.id,
				count: $0.count,
				singularLabel: $0.singularLabel,
				pluralLabel: $0.pluralLabel
			)
		}

		return WindowCloseImpactSnapshot(
			isTerminating: manager.isTerminating,
			isLastAppWindow: allWindows.count == 1 && allWindows.first === self,
			isLastMCPEnabledWindow: mcpEnabledWindowIDs.count == 1 && mcpEnabledWindowIDs.contains(windowID),
			activeItems: activityItems,
			mcp: mcpServer.closeSafetyState
		)
	}

	func closeActiveComposeTabFromShortcut() {
		guard let activeTabID = promptManager.activeComposeTabID,
			promptManager.canCloseActiveComposeTab else {
			return
		}

		Task { await promptManager.stashTab(activeTabID) }
	}

	/// Toggles IDE/Agent for global keyboard shortcuts.
	func toggleUIModeFromGlobalShortcut() {
		switch uiMode {
		case .ide:
			uiMode = .agent
		case .agent:
			uiMode = .ide
		}
	}

	/// Starts a new Agent session tab when in Agent mode (mirrors the titlebar "New Session" control).
	func startNewAgentSessionFromGlobalShortcut() {
		guard uiMode == .agent else { return }
		guard workspaceManager.activeWorkspace?.isSystemWorkspace == false else { return }

		Task {
			let activeTabID = await MainActor.run { agentModeViewModel.currentTabID }
			if await MainActor.run(body: { agentModeViewModel.shouldSwallowNewSessionClick(for: activeTabID) }) {
				return
			}
			await agentModeViewModel.createAndActivateSessionTab()
		}
	}

	func requestClose(authorization: WindowCloseAuthorization? = nil) {
		if let authorization {
			closeCoordinator.enqueueAuthorization(authorization)
		}
		nsWindow?.performClose(nil)
	}
	
	// MARK: - Agent Mode Titlebar Accessory

	@discardableResult
	private func removeTitlebarAccessory(
		_ accessory: NSTitlebarAccessoryViewController?,
		from window: NSWindow? = nil
	) -> Bool {
		guard let accessory, let window = window ?? nsWindow else { return false }
		let indexes = window.titlebarAccessoryViewControllers.enumerated().compactMap { index, candidate in
			candidate === accessory ? index : nil
		}
		guard !indexes.isEmpty else { return false }

		for index in indexes.sorted(by: >) {
			window.removeTitlebarAccessoryViewController(at: index)
		}
		configureWindowChrome(for: window)
		return true
	}

	private func detachTitlebarAccessoryControllers(from window: NSWindow?) {
		let accessories: [NSTitlebarAccessoryViewController] = [
			agentTitlebarAccessory as NSTitlebarAccessoryViewController?
		].compactMap { $0 }

		if let window, !accessories.isEmpty {
			let accessoryIDs = Set(accessories.map { ObjectIdentifier($0) })
			let indexes = window.titlebarAccessoryViewControllers.enumerated().compactMap { index, candidate in
				accessoryIDs.contains(ObjectIdentifier(candidate)) ? index : nil
			}

			for index in indexes.sorted(by: >) {
				window.removeTitlebarAccessoryViewController(at: index)
			}
			if !indexes.isEmpty {
				configureWindowChrome(for: window)
			}
		}

		agentTitlebarAccessory = nil
	}

	private func clearTitlebarAccessoryRequestsForClose() {
		wantsAgentTitlebarAccessory = false
		agentNewSessionAction = nil
	}

	/// Shows or hides the Agent mode titlebar accessory ("New Session" button near traffic lights).
	/// - Parameters:
	///   - visible: Whether to show the accessory
	///   - onNewSession: Action to call when button is tapped (required when visible is true)
	func setAgentTitlebarAccessoryVisible(_ visible: Bool, onNewSession: (() -> Void)? = nil) {
		if visible {
			guard !shouldSuppressObservationSideEffects else { return }
			wantsAgentTitlebarAccessory = true
			agentNewSessionAction = onNewSession
			applyAgentTitlebarAccessoryIfPossible()
		} else {
			wantsAgentTitlebarAccessory = false
			agentNewSessionAction = nil
			removeAgentTitlebarAccessory()
		}
	}

	/// Installs the titlebar accessory if conditions are met (Agent mode active + window attached)
	private func applyAgentTitlebarAccessoryIfPossible() {
		guard !shouldSuppressObservationSideEffects,
			wantsAgentTitlebarAccessory,
			let window = nsWindow,
			let action = agentNewSessionAction else {
			return
		}

		if let existing = agentTitlebarAccessory {
			existing.update(onNewSession: action)
			if !window.titlebarAccessoryViewControllers.contains(where: { $0 === existing }) {
				window.addTitlebarAccessoryViewController(existing)
			}
		} else {
			let accessory = AgentModeTitlebarAccessoryViewController(onNewSession: action)
			window.addTitlebarAccessoryViewController(accessory)
			agentTitlebarAccessory = accessory
		}
		configureWindowChrome(for: window)
	}

	/// Removes the titlebar accessory from the window
	private func removeAgentTitlebarAccessory() {
		let accessory = agentTitlebarAccessory
		removeTitlebarAccessory(accessory)
		agentTitlebarAccessory = nil
	}


	func requestWindowTitleUpdate(reason: WindowTitleUpdateReason = .unspecified) {
		_ = reason
		scheduleWindowTitleUpdate()
	}

	/// Updates the window title to include the workspace name and instance number
	func updateWindowTitleIfPossible() {
		requestWindowTitleUpdate(reason: .explicit)
	}

	/// Only update the window title after a deferred hop to avoid recursive layout issues.
	private func scheduleWindowTitleUpdate() {
		guard !shouldSuppressObservationSideEffects else { return }
		pendingWindowTitleUpdateTask?.cancel()
		pendingWindowTitleUpdateTask = Task { [weak self] in
			guard let self = self else { return }
			// Ensure this cannot run re-entrantly during a layout/constraints pass.
			await Task.yield()
			guard !self.shouldSuppressObservationSideEffects else { return }
			self.performWindowTitleUpdateIfWorkspaceAvailable()
		}
	}

	@MainActor
	private func performWindowTitleUpdateIfWorkspaceAvailable() {
		applyWindowTitleIfNeeded(resolvedWindowTitle())
	}

	// ------------------------------------------------------------------
	// MARK: – MCP server helpers (simple wrappers)
	// ------------------------------------------------------------------
	func startMCPServer()  { Task { try? await WindowState.sharedMCPService.join(windowID: windowID)  } }
	func stopMCPServer()   { Task { await WindowState.sharedMCPService.leave(windowID: windowID)   } }
	
	// MARK: - Command handling
	
	/// Decodes percent-encodings and expands '~' in a file path
	private func decodeAndExpandTilde(_ rawPath: String) -> String {
		// Decode percent-encoded strings, e.g. "%7E" -> "~", "%20" -> " "
		guard let decoded = rawPath.removingPercentEncoding else {
			return (rawPath as NSString).expandingTildeInPath
		}
		// Then expand '~'
		return (decoded as NSString).expandingTildeInPath
	}
	
	func enqueueCommand(_ command: AppCommand) {
		commandQueue.append(command)
		// If the workspace manager is already initialized, process now
		if workspaceManager.isInitialized {
			Task { await processCommands() }
		}
	}
	
	func applyWindowRestoreEntry(_ entry: WindowSessionEntry) {
		guard !entry.isEphemeral else { return }
		deferredGlobalUIModeFallbackOnInit = false
		applyRestoredUIModeIfAvailable(entry.uiMode)
		pendingRestoreEntry = entry
		applyPendingRestoreEntryIfPossible()
	}

	func applyDeferredGlobalUIModeFallbackIfNeeded() {
		guard deferredGlobalUIModeFallbackOnInit else { return }
		deferredGlobalUIModeFallbackOnInit = false
		applyRestoredUIModeIfAvailable(nil)
	}
	
	private func applyRestoredUIModeIfAvailable(_ restoredMode: WindowUIMode?) {
		guard AppLaunchConfiguration.current.forcedWindowUIMode == nil else { return }
		let mode = restoredMode ?? WindowInitialUIModeResolver.resolve(
			forcedMode: nil,
			globalStoredModeRawValue: UserDefaults.standard.string(forKey: "windowUIMode"),
			deferGlobalFallbackForPendingRestore: false
		)
		guard uiMode != mode else { return }
		suppressGlobalUIModePersistence = true
		defer { suppressGlobalUIModePersistence = false }
		uiMode = mode
	}
	
	private func applyPendingRestoreEntryIfPossible() {
		guard workspaceManager.isInitialized else { return }
		guard let entry = pendingRestoreEntry else { return }
		pendingRestoreEntry = nil
		
		Task {
			await restoreWorkspace(from: entry)
		}
	}
	
	private func restoreWorkspace(from entry: WindowSessionEntry) async {
		#if DEBUG
		let restoreStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		if let target = resolveWorkspace(for: entry) {
			#if DEBUG
			WorkspaceRestorePerfLog.log(
				"restore.window workspaceResolved windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(target.id)) workspaceName=\(target.name) entryWorkspaceID=\(WorkspaceRestorePerfLog.shortID(entry.workspaceID))"
			)
			#endif
			_ = await workspaceManager.requestWorkspaceSwitch(to: target, saveState: true, reason: "restore")
			#if DEBUG
			if let restoreStartMS {
				WorkspaceRestorePerfLog.log(
					"restore.window workspaceApplied windowID=\(windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(target.id)) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: restoreStartMS))"
				)
			}
			#endif
			return
		}
		
		#if DEBUG
		if let restoreStartMS {
			WorkspaceRestorePerfLog.log(
				"restore.window workspaceMissing windowID=\(windowID) entryWorkspaceID=\(WorkspaceRestorePerfLog.shortID(entry.workspaceID)) entryName=\(entry.workspaceName ?? "nil") duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: restoreStartMS))"
			)
		}
		#endif
		// No existing workspace matches; leave the window in its default state.
	}
	
	private func resolveWorkspace(for entry: WindowSessionEntry) -> WorkspaceModel? {
		let workspaces = workspaceManager.workspaces
		
		if let id = entry.workspaceID, let match = workspaces.first(where: { $0.id == id }) {
			return match
		}
		
		if let path = entry.primaryRepoPath {
			let expanded = (path as NSString).expandingTildeInPath
			if let match = workspaces.first(where: { workspace in
				workspace.repoPaths.contains { repoPath in
					(repoPath as NSString).expandingTildeInPath == expanded
				}
			}) {
				return match
			}
		}
		
		if let name = entry.workspaceName, !name.isEmpty,
		   let match = workspaces.first(where: { $0.name == name }) {
			return match
		}
		
		if entry.isSystemWorkspace,
		   let match = workspaces.first(where: { $0.isSystemWorkspace }) {
			return match
		}
		
		return nil
	}
	
	// No workspace creation fallback; restoration is best-effort for existing workspaces only.
	
	func processCommands() async {
		while !commandQueue.isEmpty {
			let command = commandQueue.removeFirst()
			await handleCommand(command)
		}
	}
	
	@MainActor
	func routeToAgentSession(_ route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
		await waitForWorkspaceInitializationForRouting()

		guard let targetWorkspace = workspaceManager.workspace(withID: route.workspaceID) else {
			return .workspaceUnavailable
		}

		NSApplication.shared.activate(ignoringOtherApps: true)
		if let window = nsWindow {
			window.makeKeyAndOrderFront(nil)
		} else {
			focusWindowIfPossible()
		}

		if workspaceManager.activeWorkspaceID != route.workspaceID {
			let switchResult = await workspaceManager.requestWorkspaceSwitch(to: targetWorkspace, saveState: true)
			if !switchResult.didSwitch, workspaceManager.activeWorkspaceID != route.workspaceID {
				return .workspaceSwitchBlocked(switchResult.message)
			}
		}

		guard let activeWorkspace = workspaceManager.activeWorkspace,
			activeWorkspace.id == route.workspaceID else {
			return .workspaceUnavailable
		}

		let tabIsActive = activeWorkspace.composeTabs.contains(where: { $0.id == route.tabID })
		let tabIsStashed = activeWorkspace.stashedTabs.contains(where: { $0.tab.id == route.tabID })
		guard tabIsActive || tabIsStashed else {
			return .tabUnavailable
		}

		if let sessionID = route.sessionID {
			let activationResult = await agentModeViewModel.activateRoutedAgentSession(
				tabID: route.tabID,
				sessionID: sessionID,
				workspace: activeWorkspace
			)
			guard activationResult == .ready else {
				return agentSessionRouteResult(for: activationResult)
			}
		}

		if tabIsStashed {
			guard await promptManager.restoreStashedComposeTab(containingTabID: route.tabID) != nil else {
				return .tabUnavailable
			}
		} else if promptManager.activeComposeTabID != route.tabID {
			await promptManager.switchComposeTab(route.tabID)
		}

		guard promptManager.activeComposeTabID == route.tabID else {
			return .tabUnavailable
		}
		guard let finalWorkspace = workspaceManager.activeWorkspace,
			finalWorkspace.id == route.workspaceID else {
			return .workspaceUnavailable
		}
		let finalActivationResult = await agentModeViewModel.activateRoutedAgentSession(
			tabID: route.tabID,
			sessionID: route.sessionID,
			workspace: finalWorkspace
		)
		guard finalActivationResult == .ready else {
			return agentSessionRouteResult(for: finalActivationResult)
		}

		if uiMode != .agent {
			uiMode = .agent
		}

		if let window = nsWindow {
			window.makeKeyAndOrderFront(nil)
		} else {
			focusWindowIfPossible()
		}
		return .routed
	}

	@MainActor
	private func waitForWorkspaceInitializationForRouting() async {
		guard !workspaceManager.isInitialized else {
			return
		}
		await workspaceManager.awaitInitialized()
	}

	private func agentSessionRouteResult(for activationResult: AgentRouteSessionActivationResult) -> AgentSessionRouteResult {
		switch activationResult {
		case .ready:
			return .routed
		case .sessionNotFound:
			return .sessionUnavailable
		case .sessionWorkspaceMismatch, .sessionTabMismatch:
			return .sessionMismatch
		case .blockedByActiveDifferentSession:
			return .blockedByActiveDifferentSession
		}
	}

	// MARK: - Handling URL commands
	func handleIncomingURL(_ url: URL) {
		guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
				comps.scheme == "repoprompt" else {
			return
		}
		
		// Check for prompt:// URLs first
		if comps.host?.lowercased() == "prompt" {
			let title = comps.queryItems?.first(where:{ $0.name == "title" })?.value?
						.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Prompt"
			let content = comps.queryItems?.first(where:{ $0.name == "content" })?.value?
						.removingPercentEncoding ?? ""
			
			// Optional "focus" flag still works
			func flag(_ name:String)->Bool?{
				guard let v = comps.queryItems?.first(where:{ $0.name==name })?.value else{ return nil }
				switch v.lowercased(){ case "1","true": return true; case "0","false": return false; default: return nil }
			}
			let focusFlag = flag("focus")
			
			let cmd = AppCommand(
				workspaceName: nil,
				fileList: [],
				promptText: nil,
				folderPath: nil,
				newPrompt: (title,content),
				focus: focusFlag,
				ephemeral: nil,
				persist: nil
			)
			
			// Send to a window exactly the same way we already do for /open
			if focusFlag == true,
			let wsMgr = self.windowStatesManager,
			let front = wsMgr.latestWindowState {          // fall back to latest-created
				front.enqueueCommand(cmd)
			} else {
				enqueueCommand(cmd)
			}
			return         // ← we handled the prompt command
		}
		
		// Require host == "open" to match repoprompt://open/~/MyProject
		guard let host = comps.host?.lowercased(), host == "open" else {
			return
		}
		
		// Strip leading slash from comps.path if present
		var rawFolderPath = comps.path
		if rawFolderPath.hasPrefix("/") {
			rawFolderPath.removeFirst()
		}
		let folderPath = rawFolderPath.isEmpty ? nil : decodeAndExpandTilde(rawFolderPath)
		
		// Extract workspaceName from ?workspace= param
		let workspaceName = comps.queryItems?
			.filter { $0.name == "workspace" }
			.compactMap { $0.value?.trimmingCharacters(in: .whitespaces) }
			.last
		
		// Extract fileList from ?files= param(s)
		let fileList: [String] = comps.queryItems?
			.filter { $0.name == "files" }
			.compactMap { $0.value }
			.flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
			.map { decodeAndExpandTilde($0) }
		?? []
		
		// Concatenate multiple prompt= params with spaces
		let promptParts = comps.queryItems?
			.filter { $0.name == "prompt" }
			.compactMap { $0.value?.removingPercentEncoding }
		?? []
		let promptText = promptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
		let finalPrompt = promptText.isEmpty ? nil : promptText
		
		// Parse focus, ephemeral, persist flags
		func boolFromQuery(_ name: String) -> Bool? {
			guard let val = comps.queryItems?.first(where: { $0.name == name })?.value else {
				return nil
			}
			let lower = val.lowercased()
			if lower == "true" || lower == "1" { return true }
			if lower == "false" || lower == "0" { return false }
			return nil
		}
		let focusFlag = boolFromQuery("focus")
		let ephemeralFlag = boolFromQuery("ephemeral")
		let persistFlag = boolFromQuery("persist")
		
		// Build an AppCommand
		let command = AppCommand(
			workspaceName: workspaceName,
			fileList: fileList,
			promptText: finalPrompt,
			folderPath: folderPath,
			newPrompt: nil,
			focus: focusFlag,
			ephemeral: ephemeralFlag,
			persist: persistFlag
		)
		
		// If we want to focus an existing window for the same folderPath, do that
		if focusFlag == true, let folderPath = folderPath {
			if let wsManager = self.windowStatesManager,
				let existingWindow = wsManager.findWindowState(forFolderPath: folderPath),
				existingWindow !== self {
				NSApplication.shared.activate(ignoringOtherApps: true)
				existingWindow.focusWindowIfPossible()
				existingWindow.enqueueCommand(command)
				return
			}
		}
		
		enqueueCommand(command)
	}
	
	@MainActor
	private func handleCommand(_ command: AppCommand) async {
		// Determine ephemeral once at the start
		let shouldBeEphemeral = (command.ephemeral == true || command.persist == false)
		var requestedWorkspaceSwitch = false
		var didSwitchWorkspace = false
		
		// Apply new prompt if provided
		if let prompt = command.newPrompt {
			// 1. add to the PromptViewModel's storage
			let stored = promptManager.addStoredPrompt(title: prompt.title,
													content: prompt.content)
			// 2. select it so it appears checked/active
			promptManager.selectNewPrompt(stored)
			
			// 3. if this window isn't front-most and focus flag was set, focus us
			if command.focus == true {
				NSApplication.shared.activate(ignoringOtherApps: true)
				self.focusWindowIfPossible()
			}
			
			// If we only have a prompt command with no other parameters, we're done
			if command.folderPath == nil && command.workspaceName == nil &&
			command.fileList.isEmpty && command.promptText == nil {
				return
			}
		}
		
		// If we have a folder path, try to open or create a workspace for it
		if let folderPath = command.folderPath, !folderPath.isEmpty {
			let folderURL = URL(fileURLWithPath: folderPath).standardizedFileURL
			var isDir: ObjCBool = false
			
			if !FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir) || !isDir.boolValue {
				// Not a valid directory
				return
			}
			
			// Try to find an existing workspace referencing this folder
			if let existingWorkspace = workspaceManager.workspaces.first(where: { ws in
				ws.repoPaths.contains { repoPath in
					let repoURL = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
						.standardizedFileURL
					return repoURL == folderURL
				}
			}) {
				// If ephemeral == true, mark existing workspace ephemeral (edge case)
				if shouldBeEphemeral {
					if let index = workspaceManager.workspaces.firstIndex(where: { $0.id == existingWorkspace.id }) {
						workspaceManager.workspaces[index].isEphemeral = true
					}
				}
				
				// If focus == true, attempt to bring up an existing window
				if command.focus == true {
					if let wsManager = self.windowStatesManager,
						let existingWindow = wsManager.findWindowState(showing: existingWorkspace.id) {
						NSApplication.shared.activate(ignoringOtherApps: true)
						existingWindow.focusWindowIfPossible()
						return
					}
				}
				
				// Switch to the existing workspace in this window
				requestedWorkspaceSwitch = true
				let result = await workspaceManager.requestWorkspaceSwitch(to: existingWorkspace, saveState: true)
				didSwitchWorkspace = result.didSwitch
			} else {
				// Create a brand-new workspace
				let nameGuess = folderURL.lastPathComponent
				let workspaceName = workspaceManager.uniqueWorkspaceName(baseName: nameGuess)
				
				// Pass ephemeral to createWorkspace
				let newWS = workspaceManager.createWorkspace(
					name: workspaceName,
					repoPaths: [folderURL.path],
					ephemeral: shouldBeEphemeral
				)
				requestedWorkspaceSwitch = true
				let result = await workspaceManager.requestWorkspaceSwitch(to: newWS, saveState: true)
				didSwitchWorkspace = result.didSwitch
			}
		}
		else if let workspaceName = command.workspaceName, !workspaceName.isEmpty {
			// Look for an existing workspace by name
			if let existing = workspaceManager.workspaces.first(where: { $0.name == workspaceName }) {
				// If ephemeral == true, mark that workspace ephemeral
				if shouldBeEphemeral {
					if let index = workspaceManager.workspaces.firstIndex(where: { $0.id == existing.id }) {
						workspaceManager.workspaces[index].isEphemeral = true
					}
				}
				
				// If focus == true, attempt to bring up existing window
				if command.focus == true {
					if let wsManager = self.windowStatesManager,
						let existingWindow = wsManager.findWindowState(showing: existing.id) {
						NSApplication.shared.activate(ignoringOtherApps: true)
						existingWindow.focusWindowIfPossible()
						return
					}
				}
				
				requestedWorkspaceSwitch = true
				let result = await workspaceManager.requestWorkspaceSwitch(to: existing, saveState: true)
				didSwitchWorkspace = result.didSwitch
			} else {
				// Create a new workspace by name
				let newWS = workspaceManager.createWorkspace(
					name: workspaceName,
					repoPaths: [],
					ephemeral: shouldBeEphemeral
				)
				requestedWorkspaceSwitch = true
				let result = await workspaceManager.requestWorkspaceSwitch(to: newWS, saveState: true)
				didSwitchWorkspace = result.didSwitch
			}
		}
		
		// If we now have an active workspace, apply file selection, prompt text, etc.
		if requestedWorkspaceSwitch && !didSwitchWorkspace {
			return
		}
		guard workspaceManager.activeWorkspace != nil else {
			return
		}
		
		if !command.fileList.isEmpty {
			await fileManager.selectFiles(withPaths: command.fileList)
		}
		
		if let prompt = command.promptText, !prompt.isEmpty {
			promptManager.promptText = prompt
		}
		
		// If focus == true and we haven't switched to another window yet, bring ourselves front
		if command.focus == true {
			NSApplication.shared.activate(ignoringOtherApps: true)
			self.focusWindowIfPossible()
		}
	}
	
	// Previous helper methods were refactored into the comprehensive handleCommand method
	
	// MARK: - Window ID Management
	
	/// Returns the ID of the most recently created window
	static func latestWindowID() -> Int {
		return windowCounter
	}
	
	// MARK: - Teardown

	func tearDown() async {
		let isAppTermination = WindowStatesManager.shared.isTerminating
		#if DEBUG
		agentChatStressHarness?.pause()
		#endif

		// Optional: persist window settings to workspace defaults if auto-persist is enabled
		if !isAppTermination, UserDefaults.standard.bool(forKey: "autoPersistWindowSettings") {
			await MainActor.run {
				settingsManager.commitAllVisitedWorkspaces()
			}
		}

		// App-level termination already coordinates agent/session and MCP shutdown.
		// Skip duplicate per-window teardown work on quit so close latency stays bounded.
		if isAppTermination {
			aiQueriesService.cancelQuery()
			return
		}

		await workspaceManager.cancelActiveSessions()
		await agentModeViewModel.prepareForWindowClose()
		WorkspaceApprovalManager.shared.cancelPending(forWindowID: windowID)

		// Stop the local MCP server
		await mcpServer.stopServer()
		
		// Cancel any ongoing AI query
		aiQueriesService.cancelQuery()

		// IMPORTANT:
		// During window close / app termination, avoid mutating UI-observed state
		// (file selections, prompt text, root folders, etc.). That churn can crash SwiftUI
		// while NSHostingView is updating constraints / tearing down.
		guard !shouldSuppressObservationSideEffects else {
			return
		}
		
		// Clear file manager state
		await fileManager.clearSelection()
		for rootFolder in fileManager.rootFolders {
			await fileManager.unloadRootFolder(rootFolder)
		}
		
		// Clear prompt manager state
		await MainActor.run {
			promptManager.clearPrompt()
		}
	}
	
	/// Attempts to bring this window to the front if possible
	func focusWindowIfPossible() {
		// Since WindowState is not an NSWindow, we can only activate the app
		// The window itself will be brought forward by the system
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	@discardableResult
	func revealPendingInteraction(tabID: UUID, surface: PendingInteractionSurface) async -> Bool {
		guard let window = nsWindow else { return false }

		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)

		switch surface {
		case .agentQuestion:
			if uiMode != .agent {
				uiMode = .agent
			}
		case .contextualQuestion:
			if uiMode != .agent, let contentViewModel {
				if contentViewModel.currentTab != .compose {
					contentViewModel.currentTab = .compose
				}
				if contentViewModel.currentView == .aiQuery {
					contentViewModel.currentView = .fileManager
				}
			}
		}

		if promptManager.activeComposeTabID != tabID {
			await promptManager.switchComposeTab(tabID)
		}

		return true
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
		pendingWindowTitleUpdateTask?.cancel()
		pendingFocusUpdateTask?.cancel()
		pendingFocusSideEffectsTask?.cancel()
		// Do not call unregisterWindowState here; deinit is nonisolated and
		// you can't hop to @MainActor. Unregistration happens in ContentView onDisappear.
	}
}
