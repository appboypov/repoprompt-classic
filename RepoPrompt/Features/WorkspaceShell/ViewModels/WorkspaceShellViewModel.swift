import AppKit
import Combine
import Foundation

/// The user-facing remove confirmation. The root view answers through `resume`.
struct RemovalPrompt: Identifiable {
	let id: UUID
	let workspaceName: String
	let hasRunningAgents: Bool
	let resume: (Bool) -> Void
}

/// Owns the single shell window, the retained runtime per catalog workspace and the published snapshot.
/// Disk stays canonical through each runtime's manager; this object only decides which runtime is shown.
@MainActor
final class WorkspaceShellViewModel: ObservableObject, WorkspaceShellCoordinating {
	static let sidebarCollapsedDefaultsKey = "workspaceShell.sidebarCollapsed"
	private static let mcpAutoStartDefaultsKey = "mcpAutoStart"

	private(set) var hostRuntime: WindowState?
	private(set) var loadedWorkspaceStates: [UUID: WindowState] = [:]
	private(set) var visibleWorkspaceID: UUID?
	/// Most recent first. Only catalog IDs.
	private(set) var visibleWorkspaceRecency: [UUID] = []
	@Published private(set) var snapshot: WorkspaceShellSnapshot = .empty
	@Published private(set) var preparingWorkspaceIDs: Set<UUID> = []
	@Published private(set) var isWorkspaceSidebarCollapsed: Bool
	@Published var isMCPToolsEnabled: Bool {
		didSet {
			guard isMCPToolsEnabled != oldValue else { return }
			hostRuntime?.mcpServer.windowToolsEnabled = isMCPToolsEnabled
			for runtime in loadedWorkspaceStates.values {
				runtime.mcpServer.windowToolsEnabled = isMCPToolsEnabled
			}
		}
	}
	@Published var pendingRemoval: RemovalPrompt?
	private(set) var isStarted = false

	private(set) var catalog: WorkspaceCatalogService?
	private let windowStatesManager: WindowStatesManager
	private let userDefaults: UserDefaults
	private weak var nativeWindow: NSWindow?
	private var windowDelegateProxy: InterceptingWindowDelegateProxy?
	private var preparationTask: Task<Void, Never>?
	private(set) var preparationQueue: [UUID] = []
	private var runtimePreparations: [UUID: Task<WindowState?, Never>] = [:]
	private var runtimeToolsCancellables: [Int: AnyCancellable] = [:]
	private var catalogObserver: AnyCancellable?
	/// False leaves non-visible runtimes unprepared until selected. Tests use it to observe the queue.
	private let preparesRemainingInBackground: Bool

	init(
		windowStatesManager: WindowStatesManager = .shared,
		userDefaults: UserDefaults = .standard,
		preparesRemainingInBackground: Bool = true
	) {
		self.windowStatesManager = windowStatesManager
		self.userDefaults = userDefaults
		self.preparesRemainingInBackground = preparesRemainingInBackground
		isWorkspaceSidebarCollapsed = userDefaults.bool(forKey: Self.sidebarCollapsedDefaultsKey)
		isMCPToolsEnabled = userDefaults.bool(forKey: Self.mcpAutoStartDefaultsKey)
		windowStatesManager.shell = self
	}

	// MARK: - Lifecycle

	func start() async {
		guard !isStarted, hostRuntime == nil else { return }
		let restoreEntry = windowStatesManager.takeShellRestoreEntry()
		let host = WindowState(launch: .shellHost)
		hostRuntime = host
		windowStatesManager.shellWindowID = host.windowID
		windowStatesManager.registerWindowState(host)
		await host.workspaceManager.awaitInitialized()
		bindRuntime(host)
		let catalog = WorkspaceCatalogService(hostRuntime: host)
		self.catalog = catalog

		let entries = catalog.loadEntries()
		let initialID = Self.resolveInitialWorkspaceID(restoreEntry: restoreEntry, entries: entries, models: host.workspaceManager.workspaces)
		preparationQueue = entries.map(\.id)
		if let initialID {
			preparationQueue.removeAll { $0 == initialID }
			preparationQueue.insert(initialID, at: 0)
		}
		observeCatalogChanges()
		publish()

		if let initialID {
			await show(initialID)
		} else {
			showRuntime(host)
		}
		if preparesRemainingInBackground {
			startBackgroundPreparation()
		}
		isStarted = true
		drainPendingURLs()
	}

	/// Tears down every runtime and the host and detaches from the manager. Reverse of `start()`.
	func stop() async {
		preparationTask?.cancel()
		preparationTask = nil
		catalogObserver = nil
		for (id, runtime) in loadedWorkspaceStates {
			if id == visibleWorkspaceID {
				runtime.attachWindow(nil)
			}
			await discard(runtime)
		}
		loadedWorkspaceStates.removeAll()
		if let hostRuntime {
			hostRuntime.attachWindow(nil)
			await discard(hostRuntime)
		}
		hostRuntime = nil
		catalog = nil
		visibleWorkspaceID = nil
		visibleWorkspaceRecency.removeAll()
		preparationQueue.removeAll()
		windowStatesManager.setVisibleWindowState(nil)
		windowStatesManager.shellWindowID = nil
		windowStatesManager.shellNSWindow = nil
		if windowStatesManager.shell === self {
			windowStatesManager.shell = nil
		}
		isStarted = false
		snapshot = .empty
	}

	/// The restore entry's workspace by id, else by primary root, else by name, else the first catalog entry.
	static func resolveInitialWorkspaceID(
		restoreEntry: WindowSessionEntry?,
		entries: [WorkspaceIndexEntry],
		models: [WorkspaceModel]
	) -> UUID? {
		let catalogIDs = Set(entries.map(\.id))
		if let entry = restoreEntry, !entry.isEphemeral {
			if let id = entry.workspaceID, catalogIDs.contains(id) {
				return id
			}
			if let root = entry.primaryRepoPath {
				let expanded = (root as NSString).expandingTildeInPath
				if let match = models.first(where: { catalogIDs.contains($0.id) && $0.repoPaths.first.map { ($0 as NSString).expandingTildeInPath } == expanded }) {
					return match.id
				}
			}
			if let name = entry.workspaceName, let match = entries.first(where: { $0.name == name }) {
				return match.id
			}
		}
		return entries.first?.id
	}

	private func startBackgroundPreparation() {
		preparationTask?.cancel()
		preparationTask = Task { [weak self] in
			while let self, !Task.isCancelled, let next = self.preparationQueue.first {
				_ = await self.ensureRuntime(for: next)
				self.preparationQueue.removeAll { $0 == next }
			}
		}
	}

	/// Returns the retained runtime, preparing it once when absent. Concurrent callers share one preparation.
	func ensureRuntime(for id: UUID) async -> WindowState? {
		if let runtime = loadedWorkspaceStates[id] {
			return runtime
		}
		if let inflight = runtimePreparations[id] {
			return await inflight.value
		}
		let task = Task<WindowState?, Never> { [weak self] in
			guard let self else { return nil }
			return await self.prepareRuntime(for: id)
		}
		runtimePreparations[id] = task
		let runtime = await task.value
		runtimePreparations[id] = nil
		return runtime
	}

	/// Builds a `.shellRuntime` state and switches its manager onto the catalog workspace exactly once.
	private func prepareRuntime(for id: UUID) async -> WindowState? {
		preparingWorkspaceIDs.insert(id)
		defer {
			preparingWorkspaceIDs.remove(id)
			preparationQueue.removeAll { $0 == id }
		}
		let state = WindowState(launch: .shellRuntime)
		windowStatesManager.registerWindowState(state)
		await state.workspaceManager.awaitInitialized()
		guard let model = state.workspaceManager.workspaces.first(where: { $0.id == id }) else {
			await discard(state)
			return nil
		}
		return await activate(state, on: model)
	}

	/// Like `prepareRuntime`, for a document the manager's catalog copy may not hold yet.
	func adoptRuntime(for model: WorkspaceModel) async -> WindowState {
		if let runtime = loadedWorkspaceStates[model.id] {
			return runtime
		}
		preparingWorkspaceIDs.insert(model.id)
		defer { preparingWorkspaceIDs.remove(model.id) }
		let state = WindowState(launch: .shellRuntime)
		windowStatesManager.registerWindowState(state)
		await state.workspaceManager.awaitInitialized()
		if !state.workspaceManager.workspaces.contains(where: { $0.id == model.id }) {
			state.workspaceManager.adoptWorkspaceModel(model)
		}
		return await activate(state, on: model)
	}

	private func activate(_ state: WindowState, on model: WorkspaceModel) async -> WindowState {
		bindRuntime(state)
		_ = await state.workspaceManager.requestWorkspaceSwitch(to: model, saveState: false, reason: "shellPreparation", origin: .shell)
		loadedWorkspaceStates[model.id] = state
		publish()
		return state
	}

	private func bindRuntime(_ state: WindowState) {
		state.mcpServer.windowToolsEnabled = isMCPToolsEnabled
		runtimeToolsCancellables[state.windowID] = state.mcpServer.$windowToolsEnabled
			.dropFirst()
			.sink { [weak self] enabled in
				guard let self, enabled, !self.isMCPToolsEnabled else { return }
				self.isMCPToolsEnabled = true
			}
		state.closeCoordinator.impactSnapshotProvider = { [weak self] in
			self?.makeCloseImpactSnapshot() ?? state.makeCloseImpactSnapshot()
		}
	}

	private func discard(_ state: WindowState) async {
		runtimeToolsCancellables[state.windowID] = nil
		await state.tearDown()
		state.beginClose()
		windowStatesManager.unregisterWindowState(state)
	}

	// MARK: - Selection

	func select(_ id: UUID) async throws {
		guard snapshot.workspaces.contains(where: { $0.id == id }) || preparationQueue.contains(id) || loadedWorkspaceStates[id] != nil else {
			throw WorkspaceShellError.unknownWorkspace(id)
		}
		await show(id)
	}

	private func show(_ id: UUID) async {
		if visibleWorkspaceID == id, loadedWorkspaceStates[id] != nil {
			return
		}
		visibleWorkspaceID = id
		preparationQueue.removeAll { $0 == id }
		preparationQueue.insert(id, at: 0)
		publish()
		guard let next = await ensureRuntime(for: id) else { return }
		// A later selection wins while this one was preparing.
		guard visibleWorkspaceID == id else { return }
		visibleWorkspaceRecency.removeAll { $0 == id }
		visibleWorkspaceRecency.insert(id, at: 0)
		showRuntime(next)
		windowStatesManager.persistWindowSession(reason: "shellSelect")
		publish()
	}

	/// Points the window, its delegate proxy and the manager's visible runtime at `next`.
	private func showRuntime(_ next: WindowState) {
		let previous = windowStatesManager.visibleWindowState
		if previous !== next {
			previous?.attachWindow(nil)
		}
		windowDelegateProxy?.windowState = next
		if let nativeWindow {
			next.attachWindow(nativeWindow, installsDelegateProxy: false)
		}
		windowStatesManager.setVisibleWindowState(next)
	}

	func runtime(for id: UUID) -> WindowState? {
		loadedWorkspaceStates[id]
	}

	var visibleRuntime: WindowState? {
		visibleWorkspaceID.flatMap { loadedWorkspaceStates[$0] }
	}

	// MARK: - Catalog

	func add(name: String, folderPath: String?, makeVisible: Bool) async throws -> UUID {
		guard let catalog else { throw WorkspaceShellError.captureFailed("shell not started") }
		let state = WindowState(launch: .shellRuntime)
		windowStatesManager.registerWindowState(state)
		await state.workspaceManager.awaitInitialized()
		let created: WorkspaceModel
		do {
			created = try await catalog.create(name: name, folderPath: folderPath, runtime: state, runtimes: Array(loadedWorkspaceStates.values))
		} catch {
			await discard(state)
			throw error
		}
		bindRuntime(state)
		loadedWorkspaceStates[created.id] = state
		publish()
		if makeVisible {
			await show(created.id)
		}
		return created.id
	}

	func rename(id: UUID, name: String) async throws {
		guard let catalog else { throw WorkspaceShellError.captureFailed("shell not started") }
		let runtime = await ensureRuntime(for: id) ?? hostRuntime
		guard let runtime else { throw WorkspaceShellError.unknownWorkspace(id) }
		try await catalog.rename(id: id, name: name, runtime: runtime, runtimes: Array(loadedWorkspaceStates.values))
		publish()
	}

	func reorder(ids: [UUID]) async throws {
		guard let catalog else { throw WorkspaceShellError.captureFailed("shell not started") }
		try await catalog.reorder(ids: ids, runtimes: Array(loadedWorkspaceStates.values))
		publish()
	}

	func setSidebarCollapsed(_ collapsed: Bool) {
		isWorkspaceSidebarCollapsed = collapsed
		userDefaults.set(collapsed, forKey: Self.sidebarCollapsedDefaultsKey)
		publish()
	}

	/// Stops the runtime's agents, deletes the catalog entry for `.removal`, tears the runtime down and
	/// moves the visible workspace to the most recent other runtime, else the first catalog entry, else none.
	func disposeRuntime(for id: UUID, reason: RuntimeDisposalReason) async {
		guard let runtime = loadedWorkspaceStates[id] else { return }
		await runtime.workspaceManager.cancelActiveSessions()
		await runtime.agentModeViewModel.prepareForWindowClose()
		if reason == .removal, let catalog {
			do {
				try await catalog.remove(id: id, runtime: runtime, runtimes: Array(loadedWorkspaceStates.values.filter { $0 !== runtime }))
			} catch {
				print("Workspace shell remove failed for \(id): \(error)")
			}
		}
		SettingsWindowCoordinator.shared.closeIfTargeting(runtime)
		WorkspaceApprovalManager.shared.cancelPending(forWindowID: runtime.windowID)
		let wasVisible = visibleWorkspaceID == id
		if wasVisible {
			runtime.attachWindow(nil)
		}
		await discard(runtime)
		loadedWorkspaceStates[id] = nil
		visibleWorkspaceRecency.removeAll { $0 == id }
		preparationQueue.removeAll { $0 == id }
		preparingWorkspaceIDs.remove(id)

		if wasVisible {
			visibleWorkspaceID = nil
			let catalogIDs = catalog?.loadEntries().map(\.id) ?? []
			let fallback = visibleWorkspaceRecency.first(where: { catalogIDs.contains($0) }) ?? catalogIDs.first
			if let fallback {
				await show(fallback)
			} else if let hostRuntime {
				showRuntime(hostRuntime)
			}
		}
		windowStatesManager.persistWindowSession(reason: "shellDispose")
		publish()
	}

	// MARK: - Window

	func attachNativeWindow(_ window: NSWindow) {
		nativeWindow = window
		windowStatesManager.shellNSWindow = window
		let current = visibleRuntime ?? hostRuntime
		if windowDelegateProxy == nil, let current {
			let proxy = InterceptingWindowDelegateProxy(windowState: current, forwardedDelegate: window.delegate)
			proxy.willCloseHandler = { [weak self] in self?.flushAllWorkspaceState() }
			windowDelegateProxy = proxy
			window.delegate = proxy
		} else if let current {
			windowDelegateProxy?.windowState = current
		}
		current?.attachWindow(window, installsDelegateProxy: false)
	}

	/// The proxy installed on the shell window, for tests and the root view.
	var installedWindowDelegateProxy: InterceptingWindowDelegateProxy? { windowDelegateProxy }

	func flushAllWorkspaceState() {
		guard !windowStatesManager.isTerminating else { return }
		hostRuntime?.workspaceManager.pollAndSaveState()
		for runtime in loadedWorkspaceStates.values {
			runtime.workspaceManager.pollAndSaveState()
		}
	}

	func makeCloseImpactSnapshot() -> WindowCloseImpactSnapshot {
		let runtimes = [hostRuntime].compactMap { $0 } + Array(loadedWorkspaceStates.values)
		return WindowCloseImpactSnapshot.aggregate(
			sessionSnapshots: runtimes.map { $0.workspaceManager.activeSessionSnapshot() },
			mcpStates: runtimes.map { $0.mcpServer.closeSafetyState },
			isTerminating: windowStatesManager.isTerminating
		)
	}

	// MARK: - Publishing

	private func observeCatalogChanges() {
		catalogObserver = NotificationCenter.default.publisher(for: .workspaceListDidChange)
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.publish() }
	}

	func publish() {
		guard let catalog, let host = hostRuntime else {
			snapshot = .empty
			return
		}
		let models = Dictionary(host.workspaceManager.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let summaries = catalog.loadEntries().map { entry -> MCPWorkspaceSummary in
			let repoPaths = models[entry.id]?.repoPaths.map { ($0 as NSString).expandingTildeInPath } ?? []
			let runtime = loadedWorkspaceStates[entry.id]
			return MCPWorkspaceSummary(
				id: entry.id,
				name: entry.name,
				allRepoPaths: repoPaths,
				showingWindowIDs: entry.id == visibleWorkspaceID ? [windowStatesManager.shellWindowID].compactMap { $0 } : [],
				isHidden: entry.isHiddenInMenus,
				isVisible: entry.id == visibleWorkspaceID,
				isAvailable: WorkspaceAvailability.isAvailable(repoPaths: repoPaths),
				hasRunningAgents: runtime.map { !$0.agentModeViewModel.tabsWithActiveAgentRun.isEmpty } ?? false
			)
		}
		snapshot = WorkspaceShellSnapshot(
			visibleWorkspaceID: visibleWorkspaceID,
			isWorkspaceSidebarCollapsed: isWorkspaceSidebarCollapsed,
			workspaces: summaries
		)
	}

	private func drainPendingURLs() {
		let urls = windowStatesManager.pendingURLs
		windowStatesManager.pendingURLs.removeAll()
		guard !urls.isEmpty else { return }
		Task { @MainActor in
			for url in urls {
				await AppDeepLinkRouter.shared.route(url: url)
			}
		}
	}
}
