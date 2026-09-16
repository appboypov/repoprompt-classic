import Foundation
import JSONSchema
import MCP
import Ontology
import SwiftUI

#if DEBUG
private func routingLog(_ message: @autoclosure () -> String) {
	//print("[WindowRouting] \(message())")
}
#else
private func routingLog(_ message: @autoclosure () -> String) {}
#endif

/// Summary info for a workspace across the app.
/// Returned by manage_workspaces with action == "list".
public struct MCPWorkspaceSummary: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// Total number of root folders in this workspace
    public let rootCount: Int
    /// First 3 root folder paths (full paths for context)
    public let repoPaths: [String]
    /// Window IDs currently showing this workspace (active in those windows)
    public let showingWindowIDs: [Int]
	/// True when this workspace is recoverable but hidden from default menus/lists.
	public let isHidden: Bool
	/// True when this workspace is the one shown in the single main window.
	public let isVisible: Bool
	/// False when at least one root folder no longer exists on disk.
	public let isAvailable: Bool
	/// True when the workspace's retained runtime has an active agent run.
	public let hasRunningAgents: Bool

    public init(
        id: UUID,
        name: String,
        allRepoPaths: [String],
        showingWindowIDs: [Int],
        isHidden: Bool = false,
        isVisible: Bool = false,
        isAvailable: Bool = true,
        hasRunningAgents: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootCount = allRepoPaths.count
        // Include first 3 paths for preview
        self.repoPaths = Array(allRepoPaths.prefix(3))
        self.showingWindowIDs = showingWindowIDs
		self.isHidden = isHidden
		self.isVisible = isVisible
		self.isAvailable = isAvailable
		self.hasRunningAgents = hasRunningAgents
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootCount = "root_count"
        case repoPaths = "repo_paths"
        case showingWindowIDs = "showing_window_ids"
		case isHidden = "is_hidden"
		case isVisible = "is_visible"
		case isAvailable = "is_available"
		case hasRunningAgents = "has_running_agents"
    }
}

/// Read-only view of the single-window workspace shell.
/// Published by the shell view model, rendered by the sidebar and returned under `shell` by manage_workspaces.
public struct WorkspaceShellSnapshot: Codable, Hashable, Sendable {
	/// Nil when no workspace is registered (empty shell).
	public let visibleWorkspaceID: UUID?
	/// Global sidebar preference.
	public let isWorkspaceSidebarCollapsed: Bool
	/// Catalog-ordered summaries, system workspaces excluded.
	public let workspaces: [MCPWorkspaceSummary]

	public init(visibleWorkspaceID: UUID?, isWorkspaceSidebarCollapsed: Bool, workspaces: [MCPWorkspaceSummary]) {
		self.visibleWorkspaceID = visibleWorkspaceID
		self.isWorkspaceSidebarCollapsed = isWorkspaceSidebarCollapsed
		self.workspaces = workspaces
	}

	public static let empty = WorkspaceShellSnapshot(visibleWorkspaceID: nil, isWorkspaceSidebarCollapsed: false, workspaces: [])

	private enum CodingKeys: String, CodingKey {
		case visibleWorkspaceID = "visible_workspace_id"
		case isWorkspaceSidebarCollapsed = "is_workspace_sidebar_collapsed"
		case workspaces
	}
}

/// Summary info for a compose tab.
/// Returned by manage_workspaces tab lifecycle actions.
public struct MCPComposeTabSummary: Codable, Hashable, Sendable {
    public let id: UUID
	public let contextID: UUID
    public let name: String
    public let workspaceID: UUID
    public let workspaceName: String
    public let windowID: Int
    public let isActive: Bool       // active tab in that window's workspace
    public let isBoundForClient: Bool // is this tab currently bound for the calling connection
    public let totalFileCount: Int  // total unique files in selection
    public let sampleFileNames: [String] // up to 3 sample file names (basename only)

    public init(
        id: UUID,
		contextID: UUID? = nil,
        name: String,
        workspaceID: UUID,
        workspaceName: String,
        windowID: Int,
        isActive: Bool,
        isBoundForClient: Bool,
        totalFileCount: Int,
        sampleFileNames: [String]
    ) {
        self.id = id
		self.contextID = contextID ?? id
        self.name = name
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.windowID = windowID
        self.isActive = isActive
        self.isBoundForClient = isBoundForClient
        self.totalFileCount = totalFileCount
        self.sampleFileNames = sampleFileNames
    }

	private enum CodingKeys: String, CodingKey {
		case id
		case contextID = "context_id"
		case name
		case workspaceID = "workspace_id"
		case workspaceName = "workspace_name"
		case windowID = "window_id"
		case isActive = "is_active"
		case isBoundForClient = "is_bound_for_client"
		case totalFileCount = "total_file_count"
		case sampleFileNames = "sample_file_names"
	}
}

/// Unified response for the manage_workspaces tool.
public struct ManageWorkspacesResponse: Codable, Sendable {
    public let action: String
    public let workspaces: [MCPWorkspaceSummary]?
    public let tabs: [MCPComposeTabSummary]?    // For create_tab / close_tab actions
    public let status: String?
    public let windowID: Int?                   // The single shell window, when known
    public let closedWindowID: Int?             // Always nil in the single-window shell; kept for decoders
    public let shell: WorkspaceShellSnapshot?   // Shell state after the action

    public init(
        action: String,
        workspaces: [MCPWorkspaceSummary]?,
        tabs: [MCPComposeTabSummary]? = nil,
        status: String?,
        windowID: Int? = nil,
        closedWindowID: Int? = nil,
        shell: WorkspaceShellSnapshot? = nil
    ) {
        self.action = action
        self.workspaces = workspaces
        self.tabs = tabs
        self.status = status
        self.windowID = windowID
        self.closedWindowID = closedWindowID
        self.shell = shell
    }
    
    private enum CodingKeys: String, CodingKey {
        case action, workspaces, tabs, status, shell
        case windowID = "window_id"
        case closedWindowID = "closed_window_id"
    }
}

public struct MCPBindContextWorkspaceSummary: Codable, Hashable, Sendable {
	public let id: UUID
	public let name: String
}

public struct MCPBindContextTabSummary: Codable, Hashable, Sendable {
	public let contextID: UUID
	public let name: String
	public let workspaceID: UUID
	public let workspaceName: String
	public let isActive: Bool
	public let isBound: Bool
	public let repoPaths: [String]

	private enum CodingKeys: String, CodingKey {
		case contextID = "context_id"
		case name
		case workspaceID = "workspace_id"
		case workspaceName = "workspace_name"
		case isActive = "is_active"
		case isBound = "is_bound"
		case repoPaths = "repo_paths"
	}
}

public struct MCPBindContextWindowSummary: Codable, Hashable, Sendable {
    public let windowID: Int
	public let isCurrentWindow: Bool
	public let workspace: MCPBindContextWorkspaceSummary?
	public let activeContextID: UUID?
	public let tabs: [MCPBindContextTabSummary]

	private enum CodingKeys: String, CodingKey {
		case windowID = "window_id"
		case isCurrentWindow = "is_current_window"
		case workspace
		case activeContextID = "active_context_id"
		case tabs
	}
}

public struct MCPBindContextBindingSummary: Codable, Equatable, Sendable {
	public let bindingKind: String
	public let windowID: Int?
	public let contextID: UUID?
	public let workspaceID: UUID?
    public let workspaceName: String?
	public let tabName: String?
	public let repoPaths: [String]
	public let explicit: Bool
	public let runScoped: Bool

    private enum CodingKeys: String, CodingKey {
		case bindingKind = "binding_kind"
        case windowID = "window_id"
		case contextID = "context_id"
		case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
		case tabName = "tab_name"
		case repoPaths = "repo_paths"
		case explicit
		case runScoped = "run_scoped"
    }
}

public struct BindContextResponse: Codable, Sendable {
	public let windows: [MCPBindContextWindowSummary]?
	public let binding: MCPBindContextBindingSummary
	public let changed: Bool?
	public let previousBinding: MCPBindContextBindingSummary?
	public let matchedBy: String?
	public let createdTab: Bool?
	public let createdWorkspace: Bool?
	public let normalizedWorkingDirs: [String]?
	public let note: String?

	private enum CodingKeys: String, CodingKey {
		case windows
		case binding
		case changed
		case previousBinding = "previous_binding"
		case matchedBy = "matched_by"
		case createdTab = "created_tab"
		case createdWorkspace = "created_workspace"
		case normalizedWorkingDirs = "normalized_working_dirs"
		case note
    }

	public init(
		windows: [MCPBindContextWindowSummary]? = nil,
		binding: MCPBindContextBindingSummary,
		changed: Bool? = nil,
		previousBinding: MCPBindContextBindingSummary? = nil,
		matchedBy: String? = nil,
		createdTab: Bool? = nil,
		createdWorkspace: Bool? = nil,
		normalizedWorkingDirs: [String]? = nil,
		note: String? = nil
	) {
		self.windows = windows
		self.binding = binding
		self.changed = changed
		self.previousBinding = previousBinding
		self.matchedBy = matchedBy
		self.createdTab = createdTab
		self.createdWorkspace = createdWorkspace
		self.normalizedWorkingDirs = normalizedWorkingDirs
		self.note = note
	}
}

/// Global service exposing bind_context and workspace/tab lifecycle helpers.
///
/// # Tools
/// • bind_context      – list, inspect, and bind sticky window/tab context.
/// • manage_workspaces – manage workspaces and compose-tab lifecycle across windows.
///
/// # Hidden Parameter Semantics
/// All MCP tools support hidden routing parameters that are extracted and stripped
/// before the tool receives its arguments. These parameters control window and tab
/// routing for the call:
///
/// ## `_windowID` (Int)
/// Explicit per-call window override. When provided:
/// - Always takes precedence over existing connection→window mappings
/// - Updates the connection's preferred window for future calls
/// - Returns an error if the window doesn't exist or has MCP disabled
///
/// ## `_tabID` (UUID)
/// Binds the connection to a specific compose tab:
/// - Evaluated after the final window is determined
/// - Tab must exist in the target window's active workspace
/// - Returns detailed error if tab not found, including window context
/// - Persists for subsequent calls until explicitly changed
///
/// # Routing Priority Order
/// 1. `_windowID` (explicit override)
/// 2. Existing connection→window mapping
/// 3. Client name reuse (same client, different connection)
/// 4. Persisted routing (token-backed sessions)
/// 5. Auto-route to active window (single-window mode)

// Simple actor for thread-safe tools storage
private actor ToolsCache {
    private var tools: [Tool] = []
    
    func update(_ newTools: [Tool]) {
        tools = newTools
    }
    
    func get() -> [Tool] {
        tools
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

@MainActor
final class WindowRoutingService: Service {
	nonisolated static func validateAddFolderWorkspace(_ workspace: WorkspaceModel) throws {
		guard workspace.isSystemWorkspace == false else {
			throw MCPError.invalidParams("Cannot add folders to system workspace '\(workspace.name)'. Create or switch to a regular workspace first.")
		}
	}

    // ---------------------------------------------------------------------
    // MARK: Stored references
    // ---------------------------------------------------------------------
	private let windowStates: WindowStatesManager
	private let networkMgr  : ServerNetworkManager
	/// Every workspace mutation from MCP goes through the shell's named actions. Nil only in tests.
	private let shellActionService: WorkspaceShellActionService?
	private var previousDisabledTools: Set<String>
    
    // Thread-safe tools storage
    private let toolsCache = ToolsCache()
    
    // NotificationCenter observer tokens for cleanup
    private var userDefaultsObserver: NSObjectProtocol?
    private var windowCountObserver: NSObjectProtocol?
    
    // ---------------------------------------------------------------------
    // MARK: Init & registration
    // ---------------------------------------------------------------------
    init(windowStates: WindowStatesManager,
         networkMgr  : ServerNetworkManager,
         shellActionService: WorkspaceShellActionService? = nil) {
        self.windowStates = windowStates
        self.networkMgr   = networkMgr
        self.shellActionService = shellActionService
		self.previousDisabledTools = Set(UserDefaults.standard.stringArray(forKey: "mcp.disabledTools") ?? [])
        
        // Initialize cached tools and register service
        Task {
            await updateCachedTools()
            
            // Register only after tools are cached
            ServiceRegistry.register(self)
        }
        
		// Listen for changes to relevant MCP settings
		userDefaultsObserver = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				
				let currentDisabledTools = Set(UserDefaults.standard.stringArray(forKey: "mcp.disabledTools") ?? [])
				
				guard currentDisabledTools != self.previousDisabledTools else { return }
				self.previousDisabledTools = currentDisabledTools
				
				let previousTools = await self.tools
				let previousToolNames = Set(previousTools.map { $0.name })
				
				await self.updateCachedTools()
				
				let newTools = await self.tools
				let newToolNames = Set(newTools.map { $0.name })
				
				let addedTools = newTools.filter { !previousToolNames.contains($0.name) }
				if !addedTools.isEmpty {
					ToolAvailabilityStore.shared.registerTools(addedTools)
				}
				
				let removedToolNames = previousToolNames.subtracting(newToolNames)
				if !removedToolNames.isEmpty {
					ToolAvailabilityStore.shared.unregisterTools(Array(removedToolNames))
				}
				
				await networkMgr.broadcastToolListChanged()
			}
		}
        
        // Listen for window count changes
        windowCountObserver = NotificationCenter.default.addObserver(
            forName: .windowCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                
                let previousTools = await self.tools
                let previousToolNames = Set(previousTools.map { $0.name })
                
                // Update cached tools based on new window count
                await self.updateCachedTools()
                
                // Update tool availability store
                let newTools = await self.tools
                let newToolNames = Set(newTools.map { $0.name })
                
                // Register newly available tools
                let addedTools = newTools.filter { !previousToolNames.contains($0.name) }
                if !addedTools.isEmpty {
                    ToolAvailabilityStore.shared.registerTools(addedTools)
                }
                
                // Unregister tools that are no longer available
                let removedToolNames = previousToolNames.subtracting(newToolNames)
                if !removedToolNames.isEmpty {
                    ToolAvailabilityStore.shared.unregisterTools(Array(removedToolNames))
                }
                
                // Notify connected clients that the tool list has changed
                await networkMgr.broadcastToolListChanged()
            }
        }
    }
    
    // ---------------------------------------------------------------------
    // MARK: Cleanup
    // ---------------------------------------------------------------------
    deinit {
        // Remove NotificationCenter observers to prevent crashes
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowCountObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // ---------------------------------------------------------------------
    // MARK: Workspace Resolution Helpers
    // ---------------------------------------------------------------------
    
	private enum WorkspaceReferenceMode {
		case visibleNameByDefault(action: String, includeHidden: Bool)
		case hide
		case unhide
	}

	private func loadWorkspaceDiskSnapshot() async throws -> [WorkspaceModel] {
		guard let referenceManager = await MainActor.run(body: {
			self.windowStates.allWindows.first?.workspaceManager
		}) else {
			throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
		}
		return await referenceManager.loadWorkspaceSnapshotFromDisk()
	}

	nonisolated private static func availableWorkspaceSuggestion(_ workspaces: [WorkspaceModel], includeHidden: Bool) -> String {
		let availableNames = workspaces
			.filter { !$0.isSystemWorkspace && (includeHidden || !$0.isHiddenInMenus) }
			.map { workspace in
				workspace.isHiddenInMenus ? "\(workspace.name) (hidden)" : workspace.name
			}
            .sorted()
		return availableNames.isEmpty
            ? "No workspaces exist. Use action 'create' to create one."
            : "Available workspaces: \(availableNames.joined(separator: ", "))"
    }

	nonisolated private static func ambiguousWorkspaceMessage(name: String, matches: [WorkspaceModel]) -> String {
		let ids = matches
			.sorted { $0.id.uuidString < $1.id.uuidString }
			.map { "\($0.name) (\($0.id.uuidString)\($0.isHiddenInMenus ? ", hidden" : ""))" }
			.joined(separator: ", ")
		return "Workspace name '\(name)' matches multiple workspaces: \(ids). Use a workspace UUID."
	}

	nonisolated private static func resolveWorkspaceReference(
		_ rawWorkspaceParam: String,
		in diskWorkspaces: [WorkspaceModel],
		mode: WorkspaceReferenceMode
	) throws -> WorkspaceModel {
		if let targetID = UUID(uuidString: rawWorkspaceParam) {
			if let found = diskWorkspaces.first(where: { $0.id == targetID }) {
				return found
			}
			throw MCPError.invalidParams("Unknown workspace id '\(rawWorkspaceParam)'")
		}

		let name = rawWorkspaceParam
		let nameMatches = diskWorkspaces.filter { $0.name == name }
		let visibleMatches = nameMatches.filter { !$0.isHiddenInMenus }
		let hiddenMatches = nameMatches.filter(\.isHiddenInMenus)

		switch mode {
		case .visibleNameByDefault(let action, let includeHidden):
			if includeHidden {
				guard nameMatches.count != 1 else { return nameMatches[0] }
				if nameMatches.count > 1 {
					throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: nameMatches))
				}
			} else {
				if visibleMatches.count == 1 {
					return visibleMatches[0]
				}
				if visibleMatches.count > 1 {
					throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: visibleMatches))
				}
				if !hiddenMatches.isEmpty {
					throw MCPError.invalidParams("Workspace '\(name)' is hidden and is excluded from name-based \(action) by default. Use include_hidden=true or address it by UUID.")
				}
			}
			throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: includeHidden))")

		case .hide:
			if visibleMatches.count == 1 { return visibleMatches[0] }
			if visibleMatches.count > 1 {
				throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: visibleMatches))
			}
			if hiddenMatches.count == 1 { return hiddenMatches[0] }
			if hiddenMatches.count > 1 {
				throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: hiddenMatches))
			}
			throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: true))")

		case .unhide:
			guard nameMatches.count != 1 else { return nameMatches[0] }
			if nameMatches.count > 1 {
				throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: nameMatches))
			}
			throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: true))")
		}
	}

	private func resolveWorkspaceForSwitch(rawWorkspaceParam: String, includeHidden: Bool) async throws -> WorkspaceModel {
		let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
		return try Self.resolveWorkspaceReference(
			rawWorkspaceParam,
			in: diskWorkspaces,
			mode: .visibleNameByDefault(action: "switch", includeHidden: includeHidden)
		)
	}

	private func resolveWorkspaceForDelete(rawWorkspaceParam: String, includeHidden: Bool) async throws -> WorkspaceModel {
		let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
		return try Self.resolveWorkspaceReference(
			rawWorkspaceParam,
			in: diskWorkspaces,
			mode: .visibleNameByDefault(action: "delete", includeHidden: includeHidden)
		)
	}

	private func resolveWorkspaceForHiddenMutation(rawWorkspaceParam: String, hidden: Bool) async throws -> WorkspaceModel {
		let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
		return try Self.resolveWorkspaceReference(
			rawWorkspaceParam,
			in: diskWorkspaces,
			mode: hidden ? .hide : .unhide
		)
	}

	nonisolated static func test_resolveWorkspaceReference(
		_ rawWorkspaceParam: String,
		workspaces: [WorkspaceModel],
		includeHiddenForName: Bool,
		action: String = "switch"
	) throws -> WorkspaceModel {
		try resolveWorkspaceReference(
			rawWorkspaceParam,
			in: workspaces,
			mode: .visibleNameByDefault(action: action, includeHidden: includeHiddenForName)
		)
	}

	nonisolated static func test_resolveWorkspaceHiddenMutationReference(
		_ rawWorkspaceParam: String,
		workspaces: [WorkspaceModel],
		hidden: Bool
	) throws -> WorkspaceModel {
		try resolveWorkspaceReference(
			rawWorkspaceParam,
			in: workspaces,
			mode: hidden ? .hide : .unhide
		)
	}

	/// The client-facing window ID for a runtime: the shell window when the shell runs, else the runtime itself.
	private func publicWindowID(for runtimeWindowID: Int) -> Int {
		windowStates.shellWindowID ?? runtimeWindowID
	}

	/// The runtime a tool call operates on. `window_id` is validated against the shell window and mapped to the
	/// connection's bound runtime, else the visible runtime, else the host. Without a shell (tests), the only window.
	private func resolveTargetRuntime(windowID: Int?) async throws -> WindowState {
		let connectionID = await self.networkMgr.currentConnectionUUID()
		let runtimeID = try await windowStates.resolveRuntimeWindowID(publicWindowID: windowID, connectionID: connectionID)
		if let runtimeID {
			guard let runtime = windowStates.allWindows.first(where: { $0.windowID == runtimeID }) else {
				throw MCPError.invalidParams("Unknown window_id \(runtimeID)")
			}
			return runtime
		}
		if windowStates.shell != nil {
			if let connectionID,
				let bound = await self.networkMgr.selectedWindow(for: connectionID),
				let runtime = windowStates.allWindows.first(where: { $0.windowID == bound }) {
				return runtime
			}
			if let visible = windowStates.visibleWindowState {
				return visible
			}
			if let host = windowStates.allWindows.first {
				return host
			}
			throw MCPError.internalError("Workspace shell has not started")
		}
		guard let only = windowStates.allWindows.only else {
			throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
		}
		return only
	}

	private var shellViewModel: WorkspaceShellViewModel {
		get throws {
			guard let shellActionService else {
				throw MCPError.internalError("Workspace shell is not available")
			}
			return shellActionService.viewModel
		}
	}

	private func requireShellActionService() throws -> WorkspaceShellActionService {
		guard let shellActionService else {
			throw MCPError.internalError("Workspace shell is not available")
		}
		return shellActionService
	}

	/// Maps shell errors onto the tool contract's error table.
	private func dispatchShellAction(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		let service = try requireShellActionService()
		do {
			return try await service.dispatch(payload)
		} catch let error as WorkspaceShellError {
			throw Self.mcpError(for: error)
		}
	}

	/// The shell state for a response; nil on the legacy path without a shell.
	private var currentShellSnapshot: WorkspaceShellSnapshot? {
		shellActionService?.viewModel.snapshot
	}

	private func resolveWorkspace(rawWorkspaceParam: String, action: String, includeHidden: Bool) async throws -> WorkspaceModel {
		let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
		return try Self.resolveWorkspaceReference(
			rawWorkspaceParam,
			in: diskWorkspaces,
			mode: .visibleNameByDefault(action: action, includeHidden: includeHidden)
		)
	}

	/// The runtime that writes a catalog mutation for `workspaceID`: its retained runtime, else the host
	/// (hidden entries have no runtime). Without a shell, the first window.
	private func catalogWriter(for workspaceID: UUID) throws -> WindowState {
		if let shell = shellActionService?.viewModel {
			if let runtime = shell.runtime(for: workspaceID) {
				return runtime
			}
			guard let host = shell.hostRuntime else {
				throw MCPError.internalError("Workspace shell has not started")
			}
			return host
		}
		guard let window = windowStates.allWindows.first else {
			throw MCPError.invalidParams("No windows available to update workspace state. Open at least one window first.")
		}
		return window
	}

	/// After a catalog write through `writer`: every other manager reloads from disk and the shell republishes.
	private func propagateCatalogWrite(from writer: WindowState) async {
		guard let shell = shellActionService?.viewModel else {
			for window in windowStates.allWindows where window !== writer {
				await window.workspaceManager.reloadWorkspacesFromDiskAsync()
			}
			return
		}
		await shell.catalog?.reloadOthers(except: writer, runtimes: Array(shell.loadedWorkspaceStates.values))
		shell.publish()
	}

	/// The runtime and model a folder mutation targets: the named workspace's writer, else the active
	/// workspace of the request's target runtime.
	private func resolveFolderMutationTarget(
		rawWorkspaceParam: String?,
		windowID: Int?,
		action: String
	) async throws -> (runtime: WindowState, workspace: WorkspaceModel) {
		if let rawWorkspaceParam, !rawWorkspaceParam.isEmpty {
			let resolved = try await resolveWorkspace(rawWorkspaceParam: rawWorkspaceParam, action: action, includeHidden: true)
			let runtime = try catalogWriter(for: resolved.id)
			guard let model = runtime.workspaceManager.workspace(withID: resolved.id) else {
				throw MCPError.invalidParams("Unknown workspace '\(rawWorkspaceParam)'")
			}
			return (runtime, model)
		}
		let runtime = try await resolveTargetRuntime(windowID: windowID)
		guard let model = runtime.workspaceManager.activeWorkspace else {
			throw MCPError.invalidParams("No active workspace. Use manage_workspaces action='list' to see available workspaces, then pass workspace=<id|name>.")
		}
		return (runtime, model)
	}

	/// A summary for one workspace after a mutation: the shell's row when it has one, else built from the model.
	private func workspaceSummary(for model: WorkspaceModel, snapshot: WorkspaceShellSnapshot?) -> MCPWorkspaceSummary {
		if let row = snapshot?.workspaces.first(where: { $0.id == model.id }) {
			return row
		}
		return MCPWorkspaceSummary(
			id: model.id,
			name: model.name,
			allRepoPaths: model.repoPaths,
			showingWindowIDs: [],
			isHidden: model.isHiddenInMenus
		)
	}

	nonisolated static func mcpError(for error: WorkspaceShellError) -> MCPError {
		switch error {
		case .unknownWorkspace(let id):
			return .invalidParams("Unknown workspace id '\(id.uuidString)'")
		case .emptyName:
			return .invalidParams("Workspace name must not be empty.")
		case .duplicateName(let name):
			return .invalidParams("A workspace named '\(name)' already exists.")
		case .invalidOrder(let detail):
			return .invalidParams("workspace_ids must list every workspace exactly once: \(detail)")
		case .approvalDenied:
			return .invalidRequest("Workspace operation was denied by the user.")
		case .cancelled:
			return .invalidRequest("Workspace operation was cancelled.")
		case .runtimeUnavailable(let id):
			return .internalError("Runtime not retained for workspace \(id.uuidString)")
		case .captureFailed(let detail):
			return .internalError(detail)
		case .invalidOutputPath(let detail):
			return .invalidParams(detail)
		}
	}

	private func resolveComposeTab(rawTabParam: String, tabs: [ComposeTabState]) throws -> ComposeTabState {
		if let tabID = UUID(uuidString: rawTabParam),
			let exactIDMatch = tabs.first(where: { $0.id == tabID }) {
			return exactIDMatch
		}

		if let exact = tabs.first(where: { $0.name == rawTabParam }) {
			return exact
		}

		let lowerParam = rawTabParam.lowercased()
		let caseInsensitiveMatches = tabs.filter { $0.name.lowercased() == lowerParam }
		if caseInsensitiveMatches.count == 1, let match = caseInsensitiveMatches.first {
			return match
		}

		let prefixMatches = tabs.filter { $0.name.lowercased().hasPrefix(lowerParam) }
		if prefixMatches.count == 1, let match = prefixMatches.first {
			return match
		}

		let availableNames = tabs.map { $0.name }.joined(separator: ", ")
		throw MCPError.invalidParams("Unknown compose tab '\(rawTabParam)'. Available tabs: \(availableNames)")
	}

	nonisolated private static func parseContextID(_ value: Value?, action: String) throws -> UUID? {
		guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return nil
		}
		guard let contextID = UUID(uuidString: raw) else {
			throw MCPError.invalidParams("Invalid context_id '\(raw)' for \(action). Expected a UUID.")
		}
		return contextID
	}

	private func resolveComposeTab(
		rawTabParam: String?,
		contextID: UUID?,
		tabs: [ComposeTabState],
		action: String
	) throws -> ComposeTabState {
		if let contextID {
			if let rawTabParam, !rawTabParam.isEmpty {
				let tabFromRaw = try resolveComposeTab(rawTabParam: rawTabParam, tabs: tabs)
				guard tabFromRaw.id == contextID else {
					throw MCPError.invalidParams("'tab' and 'context_id' target different compose tabs for '\(action)'.")
				}
				return tabFromRaw
			}

			guard let tab = tabs.first(where: { $0.id == contextID }) else {
				throw MCPError.invalidParams("Unknown compose tab context_id '\(contextID.uuidString)'.")
			}
			return tab
		}

		guard let rawTabParam, !rawTabParam.isEmpty else {
			throw MCPError.invalidParams("Missing required 'tab' or 'context_id' parameter for '\(action)' action.")
		}
		return try resolveComposeTab(rawTabParam: rawTabParam, tabs: tabs)
	}

	private func makeComposeTabSummary(
		tab: ComposeTabState,
		workspace: WorkspaceModel,
		windowID: Int,
		activeTabID: UUID?,
		boundTabID: UUID?
	) -> MCPComposeTabSummary {
		let sel = tab.selection
		let sampleK = 3
		var allPaths = Set<String>()
		allPaths.reserveCapacity(sel.selectedPaths.count + sel.slices.count + sel.autoCodemapPaths.count)

		var samplePaths: [String] = []
		samplePaths.reserveCapacity(sampleK)

		@inline(__always)
		func considerForSample(_ path: String) {
			if samplePaths.count < sampleK {
				samplePaths.append(path)
				samplePaths.sort()
				return
			}
			guard let last = samplePaths.last, path < last else { return }
			let insertIndex = samplePaths.firstIndex(where: { path < $0 }) ?? samplePaths.count
			samplePaths.insert(path, at: insertIndex)
			samplePaths.removeLast()
		}

		for path in sel.selectedPaths where allPaths.insert(path).inserted {
			considerForSample(path)
		}
		for path in sel.slices.keys where allPaths.insert(path).inserted {
			considerForSample(path)
		}
		for path in sel.autoCodemapPaths where allPaths.insert(path).inserted {
			considerForSample(path)
		}

		let sampleNames = samplePaths.map { ($0 as NSString).lastPathComponent }
		return MCPComposeTabSummary(
			id: tab.id,
			contextID: tab.id,
			name: tab.name,
			workspaceID: workspace.id,
			workspaceName: workspace.name,
			windowID: windowID,
			isActive: activeTabID == tab.id,
			isBoundForClient: boundTabID == tab.id,
			totalFileCount: allPaths.count,
			sampleFileNames: sampleNames
		)
	}
    
	struct BindContextRequest: Equatable {
		enum Operation: String {
			case list
			case status
			case bind
		}

		enum MatchKind: String {
			case contextID = "context_id"
			case workingDirs = "working_dirs"
			case windowID = "window_id"
		}

		let op: Operation
		let contextID: UUID?
		let workingDirs: [String]
		let windowID: Int?
		let createIfMissing: Bool
		let tabName: String?

		var matchKind: MatchKind? {
			if contextID != nil { return .contextID }
			if !workingDirs.isEmpty { return .workingDirs }
			if windowID != nil { return .windowID }
			return nil
		}
	}

	private struct ResolvedBindTarget {
		let windowID: Int
		let workspaceID: UUID
		let workspaceName: String
		let tabID: UUID
		let tabName: String
		let repoPaths: [String]
		let matchedBy: String
		let createdTab: Bool
		let normalizedWorkingDirs: [String]?
	}

	private struct WorkingDirsBindResolution {
		let windowID: Int
		let workspaceID: UUID
		let workspaceName: String
		let repoPaths: [String]
		let matchedBy: String
		let createdWorkspace: Bool
		let normalizedWorkingDirs: [String]
	}

	private enum WorkingDirsWorkspaceMatchKind: Equatable {
		case exact
		case superset

		var isSupersetFallback: Bool {
			self == .superset
		}

		var matchedByDescription: String {
			switch self {
			case .exact:
				return "working_dirs"
			case .superset:
				return "working_dirs (matched by workspace repo_paths superset)"
			}
		}

		var ambiguityDescription: String {
			switch self {
			case .exact:
				return "exactly matched"
			case .superset:
				return "matched by workspace repo_paths superset"
			}
		}

		var ambiguityGuidanceSubject: String {
			switch self {
			case .exact:
				return "exact matching workspaces"
			case .superset:
				return "superset matching workspaces"
			}
		}
	}

	private struct ActiveWorkspaceWindowSnapshot: Sendable {
		let windowID: Int
		let isFocused: Bool
		let workspace: WorkspaceModel
	}

	private struct WorkspaceMatch {
		let workspace: WorkspaceModel
		let showingWindowIDs: [Int]
		let kind: WorkingDirsWorkspaceMatchKind
		let normalizedRepoPaths: [String]
		let equivalentWorkspaceIDs: Set<UUID>
		let activeWorkspaceByWindowID: [Int: WorkspaceModel]

		init(
			workspace: WorkspaceModel,
			showingWindowIDs: [Int],
			kind: WorkingDirsWorkspaceMatchKind,
			normalizedRepoPaths: [String]? = nil,
			equivalentWorkspaceIDs: Set<UUID>? = nil,
			activeWorkspaceByWindowID: [Int: WorkspaceModel] = [:]
		) {
			self.workspace = workspace
			self.showingWindowIDs = showingWindowIDs.sorted()
			self.kind = kind
			self.normalizedRepoPaths = normalizedRepoPaths ?? WorkspaceRootSetKey(paths: workspace.repoPaths).normalizedPaths
			self.equivalentWorkspaceIDs = equivalentWorkspaceIDs ?? [workspace.id]
			self.activeWorkspaceByWindowID = activeWorkspaceByWindowID
		}
	}

	private struct WorkingDirsMatchSelection {
		let match: WorkspaceMatch
		let disambiguatedByWindowID: Bool
	}

	private struct LogicalContextKey: Hashable {
		let workspaceID: UUID
		let tabID: UUID
	}

	private static let bindContextWindowSelectionMessage = "Multiple windows open. Supply 'window_id' or call 'bind_context' first."

	nonisolated private static func normalizeBindingPath(_ rawPath: String) -> String {
		let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "" }
		let expanded = (trimmed as NSString).expandingTildeInPath
		return URL(fileURLWithPath: expanded).standardizedFileURL.path
	}

	nonisolated private static func parseWorkingDirs(_ value: Value?) throws -> [String] {
		guard let value else { return [] }
		let rawItems: [String]
		switch value {
		case .array(let values):
			rawItems = values.compactMap(\.stringValue)
		case .string(let raw):
			rawItems = raw
				.split(separator: ",", omittingEmptySubsequences: true)
				.map(String.init)
		default:
			throw MCPError.invalidParams("working_dirs must be an array of strings or a comma-separated string.")
		}

		var seen = Set<String>()
		var normalized: [String] = []
		for rawItem in rawItems {
			let normalizedPath = Self.normalizeBindingPath(rawItem)
			guard !normalizedPath.isEmpty else { continue }
			if seen.insert(normalizedPath).inserted {
				normalized.append(normalizedPath)
			}
		}
		return normalized
	}

	nonisolated static func parseBindContextRequest(_ args: [String: Value]) throws -> BindContextRequest {
		guard let rawOperation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			let op = BindContextRequest.Operation(rawValue: rawOperation) else {
			throw MCPError.invalidParams("bind_context requires op='list', 'status', or 'bind'.")
		}

		let contextID = try parseContextID(args["context_id"], action: "bind_context")
		let workingDirs = try parseWorkingDirs(args["working_dirs"])
		let windowID = args["window_id"]?.intValue
		let createIfMissing = args["create_if_missing"]?.boolValue ?? false
		let tabName = args["tab_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

		if op == .bind {
			if contextID != nil && !workingDirs.isEmpty {
				throw MCPError.invalidParams("bind_context op='bind' accepts exactly one primary selector: context_id, working_dirs, or window_id.")
			}
			if createIfMissing && workingDirs.isEmpty {
				throw MCPError.invalidParams("create_if_missing is only valid when binding by working_dirs.")
			}
			if tabName != nil && (workingDirs.isEmpty || !createIfMissing) {
				throw MCPError.invalidParams("tab_name is only valid when bind_context creates a blank tab via working_dirs + create_if_missing=true.")
			}
			let selectorCount = (contextID != nil ? 1 : 0) + (!workingDirs.isEmpty ? 1 : 0) + ((windowID != nil && contextID == nil && workingDirs.isEmpty) ? 1 : 0)
			guard selectorCount == 1 else {
				throw MCPError.invalidParams("bind_context op='bind' requires exactly one primary selector: context_id, working_dirs, or window_id.")
			}
		}

		return BindContextRequest(
			op: op,
			contextID: contextID,
			workingDirs: workingDirs,
			windowID: windowID,
			createIfMissing: createIfMissing,
			tabName: tabName
		)
	}

	private static func bindingKindString(_ kind: MCPServerViewModel.ConnectionBindingSnapshot.BindingKind) -> String {
		switch kind {
		case .context:
			return "context"
		case .windowOnly:
			return "window"
		case .unbound:
			return "unbound"
		}
	}

	private static func unboundBindingSnapshot() -> MCPServerViewModel.ConnectionBindingSnapshot {
		MCPServerViewModel.ConnectionBindingSnapshot(
			windowID: nil,
			tabID: nil,
			workspaceID: nil,
			workspaceName: nil,
			tabName: nil,
			repoPaths: [],
			explicitlyBound: false,
			runID: nil
		)
	}

	private func bindContextBindingSummary(from snapshot: MCPServerViewModel.ConnectionBindingSnapshot) -> MCPBindContextBindingSummary {
		MCPBindContextBindingSummary(
			bindingKind: Self.bindingKindString(snapshot.bindingKind),
			windowID: snapshot.windowID.map(publicWindowID(for:)),
			contextID: snapshot.tabID,
			workspaceID: snapshot.workspaceID,
			workspaceName: snapshot.workspaceName,
			tabName: snapshot.tabName,
			repoPaths: snapshot.repoPaths,
			explicit: snapshot.explicitlyBound,
			runScoped: snapshot.runID != nil
		)
	}

	private static func bindContextWorkspaceDisplayName(_ workspace: WorkspaceModel?) -> String? {
		guard let workspace else { return nil }
		return workspace.isSystemWorkspace ? "Default (no workspace loaded)" : workspace.name
	}

	private static func bindContextWorkspaceNote(windowID: Int, workspace: WorkspaceModel?) -> String? {
		guard let workspace, workspace.isSystemWorkspace else { return nil }
		return "Bound to window \(windowID) but no workspace is loaded. Use manage_workspaces action='switch' to load a workspace."
	}

	private func currentBindingSnapshot(for connectionID: UUID?) async -> MCPServerViewModel.ConnectionBindingSnapshot {
		guard let connectionID else {
			return Self.unboundBindingSnapshot()
		}

		let windows = self.windowStates.allWindows
		let snapshots = windows.map { ($0.windowID, $0.mcpServer.connectionBindingSnapshot(forConnection: connectionID)) }

		if let explicit = snapshots.first(where: { $0.1.bindingKind == .context && $0.1.explicitlyBound && $0.1.runID == nil }) {
			return explicit.1
		}
		if let runScoped = snapshots.first(where: { $0.1.bindingKind == .context && $0.1.runID != nil }) {
			return runScoped.1
		}
		if let context = snapshots.first(where: { $0.1.bindingKind == .context }) {
			return context.1
		}

		if let selectedWindowID = await self.networkMgr.selectedWindow(for: connectionID),
			let selectedWindow = windows.first(where: { $0.windowID == selectedWindowID }) {
			let workspace = selectedWindow.workspaceManager.activeWorkspace
			return MCPServerViewModel.ConnectionBindingSnapshot(
				windowID: selectedWindowID,
				tabID: nil,
				workspaceID: workspace?.id,
				workspaceName: Self.bindContextWorkspaceDisplayName(workspace),
				tabName: nil,
				repoPaths: workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? [],
				explicitlyBound: false,
				runID: nil
			)
		}

		return Self.unboundBindingSnapshot()
	}

	private func currentBindingSummary(for connectionID: UUID?) async -> MCPBindContextBindingSummary {
		bindContextBindingSummary(from: await currentBindingSnapshot(for: connectionID))
	}

	/// The runtime a binding refers to; the summary carries the public ID so the runtime is looked up from the snapshot.
	private func bindContextWindowNote(runtimeWindowID: Int?) -> String? {
		guard let runtimeWindowID,
			let window = self.windowStates.allWindows.first(where: { $0.windowID == runtimeWindowID }) else { return nil }
		return Self.bindContextWorkspaceNote(windowID: publicWindowID(for: runtimeWindowID), workspace: window.workspaceManager.activeWorkspace)
	}

	nonisolated private static func workspaceMatches(
		forNormalizedWorkingDirs normalizedWorkingDirs: [String],
		workspaces: [WorkspaceModel],
		kind: WorkingDirsWorkspaceMatchKind,
		includeHidden: Bool
	) -> [WorkspaceModel] {
		switch kind {
		case .exact:
			WorkspaceManagerViewModel.exactWorkspaceMatches(
				forNormalizedWorkingDirs: normalizedWorkingDirs,
				workspaces: workspaces,
				includeHidden: includeHidden
			)
		case .superset:
			WorkspaceManagerViewModel.supersetWorkspaceMatches(
				forNormalizedWorkingDirs: normalizedWorkingDirs,
				workspaces: workspaces,
				includeHidden: includeHidden
			)
		}
	}

	private static func activeWorkspaceSnapshots(from windows: [WindowState]) -> [ActiveWorkspaceWindowSnapshot] {
		windows.compactMap { window in
			guard let workspace = window.workspaceManager.activeWorkspace else { return nil }
			return ActiveWorkspaceWindowSnapshot(
				windowID: window.windowID,
				isFocused: window.isCurrentlyFocused,
				workspace: workspace
			)
		}
	}

	nonisolated private static func workspaceSort(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
		let lhsKey = lhs.name.lowercased()
		let rhsKey = rhs.name.lowercased()
		if lhsKey != rhsKey {
			return lhsKey < rhsKey
		}
		if lhs.name != rhs.name {
			return lhs.name < rhs.name
		}
		return lhs.id.uuidString < rhs.id.uuidString
	}

	nonisolated private static func preferredWorkspaceByRecencyAndName(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
		if lhs.isHiddenInMenus != rhs.isHiddenInMenus {
			return !lhs.isHiddenInMenus
		}
		if lhs.lastUsed != rhs.lastUsed {
			return lhs.lastUsed > rhs.lastUsed
		}
		if lhs.dateModified != rhs.dateModified {
			return lhs.dateModified > rhs.dateModified
		}
		return workspaceSort(lhs, rhs)
	}

	nonisolated private static func canonicalWorkspace(
		for rootSetKey: WorkspaceRootSetKey,
		candidates: [WorkspaceModel],
		activeWindowSnapshots: [ActiveWorkspaceWindowSnapshot]
	) -> WorkspaceModel? {
		let activeEquivalentSnapshots = activeWindowSnapshots
			.filter {
				!$0.workspace.isSystemWorkspace
					&& !$0.workspace.isEphemeral
					&& WorkspaceRootSetKey(paths: $0.workspace.repoPaths) == rootSetKey
			}
		if let focused = activeEquivalentSnapshots
			.filter({ $0.isFocused })
			.sorted(by: { $0.windowID < $1.windowID })
			.first {
			return focused.workspace
		}
		if let active = activeEquivalentSnapshots
			.sorted(by: { $0.windowID < $1.windowID })
			.first {
			return active.workspace
		}
		return candidates.sorted(by: preferredWorkspaceByRecencyAndName).first
	}

	nonisolated private static func collapsedWorkspaceMatches(
		normalizedWorkingDirs: [String],
		kind: WorkingDirsWorkspaceMatchKind,
		diskWorkspaces: [WorkspaceModel],
		activeWindowSnapshots: [ActiveWorkspaceWindowSnapshot],
		includeActiveWindowWorkspaces: Bool,
		includeHidden: Bool
	) -> [WorkspaceMatch] {
		var groupedCandidates: [WorkspaceRootSetKey: [UUID: WorkspaceModel]] = [:]
		for workspace in workspaceMatches(forNormalizedWorkingDirs: normalizedWorkingDirs, workspaces: diskWorkspaces, kind: kind, includeHidden: includeHidden) {
			let key = WorkspaceRootSetKey(paths: workspace.repoPaths)
			guard !key.isEmpty else { continue }
			groupedCandidates[key, default: [:]][workspace.id] = workspace
		}

		let reusableActiveSnapshots = activeWindowSnapshots.filter { snapshot in
			!snapshot.workspace.isSystemWorkspace
				&& !snapshot.workspace.isEphemeral
				&& (includeHidden || !snapshot.workspace.isHiddenInMenus)
		}

		if includeActiveWindowWorkspaces {
			for snapshot in reusableActiveSnapshots {
				let activeWorkspace = snapshot.workspace
				guard workspaceMatches(forNormalizedWorkingDirs: normalizedWorkingDirs, workspaces: [activeWorkspace], kind: kind, includeHidden: includeHidden).contains(where: { $0.id == activeWorkspace.id }) else {
					continue
				}
				let key = WorkspaceRootSetKey(paths: activeWorkspace.repoPaths)
				guard !key.isEmpty else { continue }
				groupedCandidates[key, default: [:]][activeWorkspace.id] = activeWorkspace
			}
		}

		return groupedCandidates.compactMap { key, candidatesByID -> WorkspaceMatch? in
			let candidates = Array(candidatesByID.values)
			guard !candidates.isEmpty,
				let representative = canonicalWorkspace(
					for: key,
					candidates: candidates,
					activeWindowSnapshots: reusableActiveSnapshots
				) else { return nil }
			let activeWorkspaceByWindowID = Dictionary(uniqueKeysWithValues: reusableActiveSnapshots.compactMap { snapshot -> (Int, WorkspaceModel)? in
				guard WorkspaceRootSetKey(paths: snapshot.workspace.repoPaths) == key else { return nil }
				return (snapshot.windowID, snapshot.workspace)
			})
			let equivalentWorkspaceIDs = Set(candidates.map(\.id)).union(activeWorkspaceByWindowID.values.map(\.id))
			return WorkspaceMatch(
				workspace: representative,
				showingWindowIDs: Array(activeWorkspaceByWindowID.keys).sorted(),
				kind: kind,
				normalizedRepoPaths: key.normalizedPaths,
				equivalentWorkspaceIDs: equivalentWorkspaceIDs,
				activeWorkspaceByWindowID: activeWorkspaceByWindowID
			)
		}.sorted { lhs, rhs in
			workspaceSort(lhs.workspace, rhs.workspace)
		}
	}

	private func workspaceMatchesFromDisk(
		normalizedWorkingDirs: [String],
		kind: WorkingDirsWorkspaceMatchKind
	) async throws -> [WorkspaceMatch] {
		let windows = self.windowStates.allWindows
		guard let inventoryWindow = windows.first else {
			throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
		}
		let activeWindowSnapshots = Self.activeWorkspaceSnapshots(from: windows)
		let diskWorkspaces = await inventoryWindow.workspaceManager.loadWorkspaceSnapshotFromDisk()
		return Self.collapsedWorkspaceMatches(
			normalizedWorkingDirs: normalizedWorkingDirs,
			kind: kind,
			diskWorkspaces: diskWorkspaces,
			activeWindowSnapshots: activeWindowSnapshots,
			includeActiveWindowWorkspaces: false,
			includeHidden: false
		)
	}

	private func workspaceMatchesIncludingActiveWindows(
		normalizedWorkingDirs: [String],
		kind: WorkingDirsWorkspaceMatchKind
	) async throws -> [WorkspaceMatch] {
		let windows = self.windowStates.allWindows
		guard let inventoryWindow = windows.first else {
			throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
		}
		let activeWindowSnapshots = Self.activeWorkspaceSnapshots(from: windows)
		let diskWorkspaces = await inventoryWindow.workspaceManager.loadWorkspaceSnapshotFromDisk()
		return Self.collapsedWorkspaceMatches(
			normalizedWorkingDirs: normalizedWorkingDirs,
			kind: kind,
			diskWorkspaces: diskWorkspaces,
			activeWindowSnapshots: activeWindowSnapshots,
			includeActiveWindowWorkspaces: true,
			includeHidden: false
		)
	}

	private func exactWorkspaceMatchesIncludingActiveWindows(
		normalizedWorkingDirs: [String]
	) async throws -> [WorkspaceMatch] {
		try await workspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs, kind: .exact)
	}

	private func supersetWorkspaceMatchesIncludingActiveWindows(
		normalizedWorkingDirs: [String]
	) async throws -> [WorkspaceMatch] {
		try await workspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs, kind: .superset)
	}

	nonisolated private static func workspaceMatch(
		inRequestedWindow windowID: Int,
		matches: [WorkspaceMatch]
	) -> WorkspaceMatch? {
		matches.filter { $0.showingWindowIDs.contains(windowID) }.only
	}

	nonisolated private static func selectedWorkingDirsMatch(
		in matches: [WorkspaceMatch],
		requestedWindowID windowID: Int?
	) -> WorkingDirsMatchSelection? {
		if let windowID,
			let windowDisambiguatedMatch = workspaceMatch(inRequestedWindow: windowID, matches: matches) {
			return WorkingDirsMatchSelection(match: windowDisambiguatedMatch, disambiguatedByWindowID: matches.count > 1)
		}
		if let onlyMatch = matches.only {
			return WorkingDirsMatchSelection(match: onlyMatch, disambiguatedByWindowID: false)
		}
		return nil
	}

	nonisolated private static func workingDirsMatchCandidates(
		exactMatches: [WorkspaceMatch],
		supersetMatches: [WorkspaceMatch]
	) -> [WorkspaceMatch] {
		exactMatches.isEmpty ? supersetMatches : exactMatches
	}

	nonisolated static func test_exactWorkspaceMatchForWindowID(
		_ windowID: Int,
		matches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])]
	) -> WorkspaceModel? {
		workspaceMatch(
			inRequestedWindow: windowID,
			matches: matches.map { match in
				WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .exact)
			}
		)?.workspace
	}

	nonisolated static func test_selectedWorkingDirsWorkspaceMatch(
		windowID: Int?,
		exactMatches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])],
		supersetMatches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])]
	) -> (workspace: WorkspaceModel, kind: String, matchedBy: String)? {
		let matches = workingDirsMatchCandidates(
			exactMatches: exactMatches.map { match in
				WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .exact)
			},
			supersetMatches: supersetMatches.map { match in
				WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .superset)
			}
		)
		guard let selection = selectedWorkingDirsMatch(in: matches, requestedWindowID: windowID) else { return nil }
		let kindDescription: String
		switch selection.match.kind {
		case .exact:
			kindDescription = "exact"
		case .superset:
			kindDescription = "superset"
		}
		let matchedBy = workingDirsMatchedBy(
			matchKind: selection.match.kind,
			candidateCount: matches.count,
			disambiguatedByWindowID: selection.disambiguatedByWindowID
		)
		return (selection.match.workspace, kindDescription, matchedBy)
	}

	nonisolated static func test_collapsedWorkingDirsWorkspaceMatches(
		workingDirs: [String],
		diskWorkspaces: [WorkspaceModel],
		activeWindows: [(windowID: Int, workspace: WorkspaceModel, isFocused: Bool)],
		kind: String = "exact",
		includeActiveWindowWorkspaces: Bool = true,
		includeHidden: Bool = false
	) -> [(workspace: WorkspaceModel, showingWindowIDs: [Int], equivalentWorkspaceIDs: [UUID], activeWorkspaceIDsByWindowID: [Int: UUID], normalizedRepoPaths: [String])] {
		let matchKind: WorkingDirsWorkspaceMatchKind = kind == "superset" ? .superset : .exact
		let normalizedWorkingDirs = WorkspaceManagerViewModel.normalizedExactWorkspaceDirectorySet(workingDirs)
		let snapshots = activeWindows.map { activeWindow in
			ActiveWorkspaceWindowSnapshot(
				windowID: activeWindow.windowID,
				isFocused: activeWindow.isFocused,
				workspace: activeWindow.workspace
			)
		}
		return collapsedWorkspaceMatches(
			normalizedWorkingDirs: normalizedWorkingDirs,
			kind: matchKind,
			diskWorkspaces: diskWorkspaces,
			activeWindowSnapshots: snapshots,
			includeActiveWindowWorkspaces: includeActiveWindowWorkspaces,
			includeHidden: includeHidden
		).map { match in
			(
				workspace: match.workspace,
				showingWindowIDs: match.showingWindowIDs,
				equivalentWorkspaceIDs: match.equivalentWorkspaceIDs.sorted { $0.uuidString < $1.uuidString },
				activeWorkspaceIDsByWindowID: match.activeWorkspaceByWindowID.mapValues(\.id),
				normalizedRepoPaths: match.normalizedRepoPaths
			)
		}
	}

	nonisolated static func preferredOpenWindowID(
		showingWindowIDs: [Int],
		selectedWindowID: Int?,
		focusedWindowID: Int?
	) -> Int? {
		if let selectedWindowID, showingWindowIDs.contains(selectedWindowID) {
			return selectedWindowID
		}
		if let focusedWindowID, showingWindowIDs.contains(focusedWindowID) {
			return focusedWindowID
		}
		return showingWindowIDs.sorted().first
	}

	nonisolated static func test_preferredOpenWindowID(
		showingWindowIDs: [Int],
		selectedWindowID: Int?,
		focusedWindowID: Int?
	) -> Int? {
		preferredOpenWindowID(
			showingWindowIDs: showingWindowIDs,
			selectedWindowID: selectedWindowID,
			focusedWindowID: focusedWindowID
		)
	}

	/// Shows `workspace` in the shell and returns its retained runtime.
	private func showWorkspaceInShell(_ workspace: WorkspaceModel) async throws -> WindowState {
		let service = try requireShellActionService()
		let result = await service.forwardSwitch(workspace)
		switch result {
		case .switched:
			break
		case .cancelled(let message):
			throw MCPError.invalidRequest(message)
		case .blocked(let message):
			throw MCPError.invalidParams(message)
		}
		guard let runtime = service.viewModel.runtime(for: workspace.id) else {
			throw MCPError.internalError("Runtime not retained for workspace \(workspace.id.uuidString)")
		}
		return runtime
	}

	/// Creates a workspace through `workspace_shell.add` (tool approval included) and returns its runtime and model.
	/// Roots after the first are added on the runtime, since the catalog creates with at most one root.
	private func createWorkspaceInShell(
		name: String,
		repoPaths: [String],
		makeVisible: Bool,
		clientID: String
	) async throws -> (workspace: WorkspaceModel, runtime: WindowState) {
		let snapshot = try await dispatchShellAction(.add(AddWorkspacePayload(
			name: name,
			folderPath: repoPaths.first,
			makeVisible: makeVisible,
			source: .tool(clientID: clientID)
		)))
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let created = snapshot.workspaces.first(where: { $0.name == trimmedName }),
			let runtime = try shellViewModel.runtime(for: created.id) else {
			throw MCPError.internalError("Runtime not retained for created workspace '\(trimmedName)'")
		}
		for path in repoPaths.dropFirst() {
			guard let current = runtime.workspaceManager.workspace(withID: created.id) else { break }
			do {
				try await runtime.workspaceManager.addFolder(URL(fileURLWithPath: path), to: current)
			} catch {
				throw MCPError.internalError("Failed to add folder '\(path)': \(error.localizedDescription)")
			}
		}
		guard let model = runtime.workspaceManager.workspace(withID: created.id) else {
			throw MCPError.internalError("Created workspace '\(trimmedName)' is not loaded")
		}
		return (model, runtime)
	}

	private func derivedWorkspaceName(
		normalizedWorkingDirs: [String],
		creationNameHint: String?,
		existingWorkspaces: [WorkspaceModel]
	) -> String {
		let trimmedHint = creationNameHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let derivedBaseName = normalizedWorkingDirs
			.map { URL(fileURLWithPath: $0).lastPathComponent }
			.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			.joined(separator: ", ")
		let baseName = trimmedHint.isEmpty ? derivedBaseName : trimmedHint
		let resolvedBaseName = baseName.isEmpty ? "Workspace" : baseName
		if !existingWorkspaces.contains(where: { $0.name == resolvedBaseName }) {
			return resolvedBaseName
		}
		var counter = 1
		var candidate = "\(resolvedBaseName) (\(counter))"
		while existingWorkspaces.contains(where: { $0.name == candidate }) {
			counter += 1
			candidate = "\(resolvedBaseName) (\(counter))"
		}
		return candidate
	}

	private func describeWorkspaceMatches(_ matches: [WorkspaceMatch]) -> String {
		matches.map { match in
			let windows = match.showingWindowIDs.isEmpty ? "none" : match.showingWindowIDs.map(String.init).joined(separator: ", ")
			return "workspace=\(match.workspace.name) (\(match.workspace.id.uuidString)) • windows=[\(windows)]"
		}.joined(separator: "\n- ")
	}

	private func workingDirsAmbiguityMessage(
		normalizedWorkingDirs: [String],
		matches: [WorkspaceMatch],
		windowID: Int?,
		afterApproval: Bool = false
	) -> String {
		let phaseSuffix = afterApproval ? " after approval" : ""
		let kind = matches.first?.kind ?? .exact
		let guidance: String
		switch (kind, windowID) {
		case (.superset, let windowID?):
			guidance = "window_id=\(windowID) did not disambiguate because that window is not showing exactly one of the superset matching workspaces. Supply window_id for a window showing the intended workspace, bind by context_id, or pass the full workspace repo_paths set to get an exact match."
		case (.superset, nil):
			guidance = "Supply window_id for a window showing the intended workspace, bind by context_id, or pass the full workspace repo_paths set to get an exact match."
		case (.exact, let windowID?):
			guidance = "window_id=\(windowID) did not disambiguate because that window is not showing exactly one of the \(kind.ambiguityGuidanceSubject). Delete the duplicate workspace with manage_workspaces action='delete'."
		case (.exact, nil):
			guidance = "Supply window_id to disambiguate, or delete the duplicate workspace with manage_workspaces action='delete'."
		}
		return "working_dirs [\(normalizedWorkingDirs.joined(separator: ", "))] \(kind.ambiguityDescription) multiple workspaces\(phaseSuffix):\n- \(describeWorkspaceMatches(matches))\n\(guidance)"
	}

	nonisolated private static func workingDirsMatchedBy(
		matchKind: WorkingDirsWorkspaceMatchKind,
		candidateCount: Int,
		disambiguatedByWindowID: Bool
	) -> String {
		let baseDescription = matchKind.matchedByDescription
		guard disambiguatedByWindowID else { return baseDescription }
		let disambiguationDescription = "disambiguated by window_id from \(candidateCount) candidates"
		switch matchKind {
		case .exact:
			return "working_dirs (\(disambiguationDescription))"
		case .superset:
			return "working_dirs (matched by workspace repo_paths superset; \(disambiguationDescription))"
		}
	}

	nonisolated static func test_workingDirsMatchedBy(candidateCount: Int, disambiguatedByWindowID: Bool) -> String {
		workingDirsMatchedBy(matchKind: .exact, candidateCount: candidateCount, disambiguatedByWindowID: disambiguatedByWindowID)
	}

	nonisolated static func test_supersetWorkingDirsMatchedBy(candidateCount: Int, disambiguatedByWindowID: Bool) -> String {
		workingDirsMatchedBy(matchKind: .superset, candidateCount: candidateCount, disambiguatedByWindowID: disambiguatedByWindowID)
	}

	private func workingDirsResolution(
		windowID: Int,
		workspace: WorkspaceModel,
		normalizedWorkingDirs: [String],
		matchedBy: String,
		createdWorkspace: Bool
	) -> WorkingDirsBindResolution {
		WorkingDirsBindResolution(
			windowID: windowID,
			workspaceID: workspace.id,
			workspaceName: workspace.name,
			repoPaths: workspace.repoPaths,
			matchedBy: matchedBy,
			createdWorkspace: createdWorkspace,
			normalizedWorkingDirs: normalizedWorkingDirs
		)
	}

	/// The retained runtime for `workspace`, prepared in the background when absent. Never changes the visible workspace.
	private func retainedRuntime(for workspace: WorkspaceModel) async throws -> WindowState {
		let shell = try shellViewModel
		if let runtime = shell.runtime(for: workspace.id) {
			return runtime
		}
		if let runtime = await shell.ensureRuntime(for: workspace.id) {
			return runtime
		}
		return await shell.adoptRuntime(for: workspace)
	}

	private func resolveMatchToWindow(
		_ match: WorkspaceMatch,
		connectionID: UUID?,
		normalizedWorkingDirs: [String],
		matchedBy: String,
		createdWorkspace: Bool
	) async throws -> WorkingDirsBindResolution {
		let selectedWindowID: Int? = if let connectionID {
			await self.networkMgr.selectedWindow(for: connectionID)
		} else {
			nil
		}
		let focusedWindowID = self.windowStates.allWindows.first(where: { $0.isCurrentlyFocused })?.windowID
		if let preferredWindowID = Self.preferredOpenWindowID(
			showingWindowIDs: match.showingWindowIDs,
			selectedWindowID: selectedWindowID,
			focusedWindowID: focusedWindowID
		) {
			if let activeEquivalentWorkspace = match.activeWorkspaceByWindowID[preferredWindowID] {
				return workingDirsResolution(
					windowID: preferredWindowID,
					workspace: activeEquivalentWorkspace,
					normalizedWorkingDirs: normalizedWorkingDirs,
					matchedBy: matchedBy,
					createdWorkspace: createdWorkspace
				)
			}

			if let targetWindow = self.windowStates.allWindows.first(where: { $0.windowID == preferredWindowID }) {
				if targetWindow.workspaceManager.activeWorkspace?.id != match.workspace.id {
					let switchResult = await targetWindow.workspaceManager.requestWorkspaceSwitch(to: match.workspace, saveState: true)
					if !switchResult.didSwitch {
						throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
					}
				}
				return workingDirsResolution(
					windowID: targetWindow.windowID,
					workspace: match.workspace,
					normalizedWorkingDirs: normalizedWorkingDirs,
					matchedBy: matchedBy,
					createdWorkspace: createdWorkspace
				)
			}
		}

		let runtime = try await retainedRuntime(for: match.workspace)
		return workingDirsResolution(
			windowID: runtime.windowID,
			workspace: match.workspace,
			normalizedWorkingDirs: normalizedWorkingDirs,
			matchedBy: matchedBy,
			createdWorkspace: createdWorkspace
		)
	}

	private func resolveExistingWorkingDirsMatch(
		_ match: WorkspaceMatch,
		requestedWindowID: Int?,
		connectionID: UUID?,
		normalizedWorkingDirs: [String],
		matchedBy: String,
		createdWorkspace: Bool
	) async throws -> WorkingDirsBindResolution {
		if let requestedWindowID, windowStates.shell == nil {
			let windows = self.windowStates.allWindows
			guard let requestedWindow = windows.first(where: { $0.windowID == requestedWindowID }) else {
				let validIDs = windows.map(\.windowID).sorted().map(String.init).joined(separator: ", ")
				throw MCPError.invalidParams("Requested window_id \(requestedWindowID) is no longer available. Valid window IDs: \(validIDs)")
			}
			if let activeEquivalentWorkspace = match.activeWorkspaceByWindowID[requestedWindowID] {
				return workingDirsResolution(
					windowID: requestedWindow.windowID,
					workspace: activeEquivalentWorkspace,
					normalizedWorkingDirs: normalizedWorkingDirs,
					matchedBy: matchedBy,
					createdWorkspace: createdWorkspace
				)
			}
			if requestedWindow.workspaceManager.activeWorkspace?.id != match.workspace.id {
				let switchResult = await requestedWindow.workspaceManager.requestWorkspaceSwitch(to: match.workspace, saveState: true)
				if !switchResult.didSwitch {
					throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
				}
			}
			return workingDirsResolution(
				windowID: requestedWindow.windowID,
				workspace: match.workspace,
				normalizedWorkingDirs: normalizedWorkingDirs,
				matchedBy: matchedBy,
				createdWorkspace: createdWorkspace
			)
		}

		return try await resolveMatchToWindow(
			match,
			connectionID: connectionID,
			normalizedWorkingDirs: normalizedWorkingDirs,
			matchedBy: matchedBy,
			createdWorkspace: createdWorkspace
		)
	}

	private func ensureResolvedWorkspaceIsLoaded(_ resolution: WorkingDirsBindResolution) throws {
		guard let targetWindow = self.windowStates.allWindows.first(where: { $0.windowID == resolution.windowID }),
			let activeWorkspace = targetWindow.workspaceManager.activeWorkspace,
			activeWorkspace.id == resolution.workspaceID else {
			let windowID = publicWindowID(for: resolution.windowID)
			throw MCPError.invalidRequest(
				"Workspace '\(resolution.workspaceName)' was matched but is not loaded in window \(windowID). Use manage_workspaces action='switch' workspace='\(resolution.workspaceName)' to load it."
			)
		}
	}

	private func resolveExistingWorkingDirsBindResolution(
		normalizedWorkingDirs: [String],
		windowID: Int?,
		connectionID: UUID?,
		afterApproval: Bool
	) async throws -> WorkingDirsBindResolution? {
		// One physical window under the shell: window_id validates the caller but never disambiguates matches.
		let windowID = windowStates.shell == nil ? windowID : nil
		let exactMatches = try await exactWorkspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs)
		let supersetMatches = exactMatches.isEmpty
			? try await supersetWorkspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs)
			: []
		let matches = Self.workingDirsMatchCandidates(exactMatches: exactMatches, supersetMatches: supersetMatches)
		let matchSelection = Self.selectedWorkingDirsMatch(in: matches, requestedWindowID: windowID)
		if matches.count > 1,
			matchSelection == nil {
			throw MCPError.invalidParams(
				workingDirsAmbiguityMessage(
					normalizedWorkingDirs: normalizedWorkingDirs,
					matches: matches,
					windowID: windowID,
					afterApproval: afterApproval
				)
			)
		}

		guard let matchSelection else { return nil }
		let match = matchSelection.match
		let matchedBy = Self.workingDirsMatchedBy(
			matchKind: match.kind,
			candidateCount: matches.count,
			disambiguatedByWindowID: matchSelection.disambiguatedByWindowID
		)
		let resolution = try await resolveExistingWorkingDirsMatch(
			match,
			requestedWindowID: windowID,
			connectionID: connectionID,
			normalizedWorkingDirs: normalizedWorkingDirs,
			matchedBy: matchedBy,
			createdWorkspace: false
		)
		try ensureResolvedWorkspaceIsLoaded(resolution)
		return resolution
	}

	/// Validates a caller-supplied window ID: the shell window under the shell, else a live window.
	private func validateRequestedWindowID(_ windowID: Int?) throws {
		guard let windowID else { return }
		if let shellWindowID = windowStates.shellWindowID {
			guard windowID == shellWindowID else {
				throw MCPError.invalidParams("window_id \(windowID) is not the RepoPrompt window. Valid window ID: \(shellWindowID)")
			}
			return
		}
		let windows = self.windowStates.allWindows
		guard windows.contains(where: { $0.windowID == windowID }) else {
			let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
			throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
		}
	}

	private func resolveContextIDBindTarget(contextID: UUID, windowID: Int?, connectionPreferredWindowID: Int?) throws -> ResolvedBindTarget {
		try validateRequestedWindowID(windowID)
		let windows = self.windowStates.allWindows
		// Under the shell every retained runtime is searched; the public ID never narrows the search.
		let filterWindowID = windowStates.shell == nil ? windowID : nil

		let matches = windows.compactMap { window -> ResolvedBindTarget? in
			guard filterWindowID == nil || window.windowID == filterWindowID else { return nil }
			guard let candidate = window.workspaceManager.bindingCandidate(forContextID: contextID) else { return nil }
			let tabName = window.workspaceManager.composeTabName(with: candidate.tabID) ?? contextID.uuidString
			return ResolvedBindTarget(
				windowID: window.windowID,
				workspaceID: candidate.workspaceID,
				workspaceName: candidate.workspaceName,
				tabID: candidate.tabID,
				tabName: tabName,
				repoPaths: candidate.repoPaths,
				matchedBy: "context_id",
				createdTab: false,
				normalizedWorkingDirs: nil
			)
		}

		guard !matches.isEmpty else {
			if let windowID {
				throw MCPError.invalidParams("Window \(windowID) does not host context_id '\(contextID.uuidString)'.")
			}
			throw MCPError.invalidParams("No RepoPrompt context matches context_id '\(contextID.uuidString)'. Use bind_context op=list to discover available context_id values.")
		}

		if matches.count == 1 {
			return matches[0]
		}

		// Same logical tab visible in multiple windows.
		// Prefer the connection's current window to avoid silently rebinding.
		if let connectionPreferredWindowID,
			let preferred = matches.first(where: { $0.windowID == connectionPreferredWindowID }) {
			return preferred
		}

		// Fall back to deterministic selection (lowest window ID).
		return matches.sorted(by: { $0.windowID < $1.windowID })[0]
	}

	private func resolveWorkingDirsBindTarget(
		workingDirs: [String],
		windowID: Int?,
		createIfMissing: Bool,
		tabName: String?,
		connectionID: UUID?
	) async throws -> WorkingDirsBindResolution {
		try validateRequestedWindowID(windowID)

		let normalizedWorkingDirs = WorkspaceManagerViewModel.normalizedExactWorkspaceDirectorySet(workingDirs)
		guard !normalizedWorkingDirs.isEmpty else {
			throw MCPError.invalidParams("working_dirs must contain at least one valid absolute directory path.")
		}

		if let resolution = try await resolveExistingWorkingDirsBindResolution(
			normalizedWorkingDirs: normalizedWorkingDirs,
			windowID: windowID,
			connectionID: connectionID,
			afterApproval: false
		) {
			return resolution
		}

		guard createIfMissing else {
			throw MCPError.invalidParams(
				"No existing workspace exactly matches working_dirs [\(normalizedWorkingDirs.joined(separator: ", "))] and no workspace repo_paths superset contains those roots. Exact matching uses the full workspace repo_paths set (order-insensitive); superset fallback uses root-set membership only, not descendant paths. Retry with create_if_missing=true to create one."
			)
		}

		let referenceManager = try await resolveTargetRuntime(windowID: windowID).workspaceManager
		let existingWorkspaces = await referenceManager.loadWorkspaceSnapshotFromDisk()
		let workspaceName = derivedWorkspaceName(
			normalizedWorkingDirs: normalizedWorkingDirs,
			creationNameHint: tabName,
			existingWorkspaces: existingWorkspaces
		)
		let clientID = await self.networkMgr.currentClientIdentifier() ?? "unknown-client"
		// A background binding never changes what the user sees.
		let created = try await createWorkspaceInShell(
			name: workspaceName,
			repoPaths: normalizedWorkingDirs,
			makeVisible: false,
			clientID: clientID
		)
		return WorkingDirsBindResolution(
			windowID: created.runtime.windowID,
			workspaceID: created.workspace.id,
			workspaceName: created.workspace.name,
			repoPaths: created.workspace.repoPaths,
			matchedBy: "working_dirs",
			createdWorkspace: true,
			normalizedWorkingDirs: normalizedWorkingDirs
		)
	}

	private func clearNonRunScopedBindingsAcrossWindows(for connectionID: UUID) {
		for window in self.windowStates.allWindows {
			_ = window.mcpServer.clearNonRunScopedBinding(forConnection: connectionID)
		}
	}

	private func bindTarget(
		_ target: ResolvedBindTarget,
		connectionID: UUID,
		clientName: String?
	) async throws {
		guard let targetWindow = self.windowStates.allWindows.first(where: { $0.windowID == target.windowID }) else {
			throw MCPError.invalidParams("Window \(target.windowID) not found")
		}
		clearNonRunScopedBindingsAcrossWindows(for: connectionID)
		try targetWindow.mcpServer.bindTabForConnection(
			connectionID: connectionID,
			clientName: clientName,
			tabID: target.tabID,
			workspaceID: target.workspaceID,
			windowID: target.windowID
		)
		try await self.networkMgr.setActiveWindowForCurrentConnection(target.windowID)
	}

	private func bindWindowOnly(windowID: Int, connectionID: UUID) async throws {
		guard windowStates.hasWindow(id: windowID) else {
			throw MCPError.invalidParams("Window \(windowID) not found")
		}
		clearNonRunScopedBindingsAcrossWindows(for: connectionID)
		try await self.networkMgr.setActiveWindowForCurrentConnection(windowID)
	}

	private func listBindContextWindows(
		filterWindowID: Int?,
		currentWindowID: Int?,
		bindingSummary: MCPBindContextBindingSummary
	) throws -> [MCPBindContextWindowSummary] {
		try validateRequestedWindowID(filterWindowID)
		if let shellWindowID = windowStates.shellWindowID {
			return [shellBindContextWindowSummary(shellWindowID: shellWindowID, bindingSummary: bindingSummary)]
		}
		let windows = self.windowStates.allWindows
		return windows.compactMap { window in
			guard filterWindowID == nil || window.windowID == filterWindowID else { return nil }
			let workspace = window.workspaceManager.activeWorkspace
			let activeContextID = workspace?.activeComposeTabID
			return MCPBindContextWindowSummary(
				windowID: window.windowID,
				isCurrentWindow: currentWindowID == window.windowID,
				workspace: workspace.map { MCPBindContextWorkspaceSummary(id: $0.id, name: Self.bindContextWorkspaceDisplayName($0) ?? $0.name) },
				activeContextID: activeContextID,
				tabs: bindContextTabSummaries(for: window, bindingSummary: bindingSummary)
			)
		}
	}

	/// One entry for the shell window: the visible workspace, its active tab and every retained runtime's tabs.
	/// An empty catalog yields no workspace, no active context and no tabs.
	private func shellBindContextWindowSummary(shellWindowID: Int, bindingSummary: MCPBindContextBindingSummary) -> MCPBindContextWindowSummary {
		let visible = windowStates.visibleWindowState
		let workspace = visible?.workspaceManager.activeWorkspace.flatMap { $0.isSystemWorkspace ? nil : $0 }
		let runtimes = windowStates.allWindows.filter { $0.launch == .shellRuntime }
		return MCPBindContextWindowSummary(
			windowID: shellWindowID,
			isCurrentWindow: true,
			workspace: workspace.map { MCPBindContextWorkspaceSummary(id: $0.id, name: $0.name) },
			activeContextID: workspace?.activeComposeTabID,
			tabs: runtimes.flatMap { bindContextTabSummaries(for: $0, bindingSummary: bindingSummary) }
		)
	}

	private func bindContextTabSummaries(for window: WindowState, bindingSummary: MCPBindContextBindingSummary) -> [MCPBindContextTabSummary] {
		guard let workspace = window.workspaceManager.activeWorkspace, !(windowStates.shell != nil && workspace.isSystemWorkspace) else {
			return []
		}
		let activeContextID = workspace.activeComposeTabID
		let workspaceName = Self.bindContextWorkspaceDisplayName(workspace) ?? ""
		let repoPaths = WorkspaceManagerViewModel.loadableRepoPaths(for: workspace)
		let publicID = publicWindowID(for: window.windowID)
		return workspace.composeTabs.map { tab in
			MCPBindContextTabSummary(
				contextID: tab.id,
				name: tab.name,
				workspaceID: workspace.id,
				workspaceName: workspaceName,
				isActive: activeContextID == tab.id,
				isBound: bindingSummary.bindingKind == "context" && bindingSummary.windowID == publicID && bindingSummary.contextID == tab.id,
				repoPaths: repoPaths
			)
		}
	}

    // ---------------------------------------------------------------------
    // MARK: Private Helpers
    // ---------------------------------------------------------------------
	private func updateCachedTools() async {
		var newTools: [Tool] = []
		
		newTools.append(
			Tool(
				name: "bind_context",
				description: """
List, inspect, and bind sticky RepoPrompt workspace/tab context for this MCP connection.

RepoPrompt runs a single window. Every registered workspace stays loaded in memory, so binding to a workspace that is not visible never changes what the user sees.

Operations:
• list    – return the RepoPrompt window, the visible workspace, every loaded workspace's compose tabs, and this connection's current binding
• status  – return this connection's current binding only
• bind    – bind by working_dirs (preferred), context_id, or window_id

**Recommended binding flow:**
Bind by `working_dirs` using absolute workspace root paths:
	`{"op":"bind","working_dirs":["/path/to/root1","/path/to/root2"]}`
RepoPrompt first looks for an exact workspace `repo_paths` set match (order-insensitive). If no exact match exists, RepoPrompt may fall back to a workspace whose `repo_paths` is a strict superset of the requested roots. Both modes match workspace roots only — not descendant paths.
The matching workspace is bound in the background; the visible workspace stays as it is. Add `create_if_missing=true` to create a new workspace after approval when neither exact nor superset workspace matches.

Parameters:
- op: "list" | "status" | "bind" (required)
- working_dirs: string | string[]         (for bind: preferred — absolute workspace roots; exact match first, repo_paths superset fallback)
- context_id: string                      (for bind: canonical compose-tab context UUID from a previous list)
- window_id: integer                      (optional; the RepoPrompt window only. For bind alone: bind to the visible workspace)
- create_if_missing: boolean              (for bind with working_dirs; create a new workspace after approval when no exact or superset workspace matches)
- tab_name: string                        (optional workspace name hint when creating via working_dirs + create_if_missing)

**Binding modes:**
- **Workspace affinity** (from working_dirs or window_id): routes tool calls to whichever tab is currently active in that workspace. Most agents should use this.
- **Tab binding** (from context_id): pins tool calls to a specific compose tab, even if you switch to another tab. Use when you need a stable context that won't change.

**Discovery:**
- Use `bind_context list` to see what's currently open (windows, active workspaces, tabs, context_ids)
- Use `manage_workspaces list` to see saved visible workspaces, or `include_hidden=true` to include recoverable hidden workspaces
""",
				inputSchema: .object(
					properties: [
						"op": .string(description: "Operation: 'list', 'status', or 'bind'", enum: ["list", "status", "bind"]),
						"window_id": .integer(description: "For list: filter to one window. For bind with working_dirs: disambiguate when multiple workspaces match. For bind alone: set window affinity."),
						"context_id": .string(description: "For bind: canonical compose-tab context UUID"),
						"working_dirs": .string(description: "For bind: comma-separated absolute workspace root paths; exact match first, then repo_paths superset fallback"),
						"create_if_missing": .boolean(description: "For bind with working_dirs: create a new workspace after approval if no exact or superset workspace matches"),
						"tab_name": .string(description: "Optional workspace name when creating via working_dirs + create_if_missing")
					],
					required: ["op"]
				),
				annotations: .repoPromptLocalEphemeralState
			) { [weak self] args -> BindContextResponse in
				guard let self else {
					throw MCPError.internalError("Service unavailable")
				}

				let request = try Self.parseBindContextRequest(args)
				let connectionID = await self.networkMgr.currentConnectionUUID()

				switch request.op {
				case .list:
					let binding = await self.currentBindingSummary(for: connectionID)
					let selectedWindowID: Int?
					if let connectionID {
						selectedWindowID = await self.networkMgr.selectedWindow(for: connectionID)
					} else {
						selectedWindowID = nil
					}
					let focusedWindowID = await MainActor.run {
						self.windowStates.allWindows.first(where: { $0.isCurrentlyFocused })?.windowID
					}
					let currentWindowID = binding.windowID ?? selectedWindowID ?? focusedWindowID
					let windows = try await MainActor.run {
						try self.listBindContextWindows(
							filterWindowID: request.windowID,
							currentWindowID: currentWindowID,
							bindingSummary: binding
						)
					}
					return BindContextResponse(windows: windows, binding: binding)

				case .status:
					return BindContextResponse(binding: await self.currentBindingSummary(for: connectionID))

				case .bind:
					guard let connectionID else {
						throw MCPError.internalError("No active connection context")
					}
					let previousBinding = await self.currentBindingSummary(for: connectionID)
					let clientName = await self.networkMgr.currentClientIdentifier()
						switch request.matchKind {
						case .contextID:
							let connectionPreferredWindow = await self.networkMgr.selectedWindow(for: connectionID)
							let target = try await MainActor.run {
								try self.resolveContextIDBindTarget(contextID: request.contextID!, windowID: request.windowID, connectionPreferredWindowID: connectionPreferredWindow)
							}
							let targetPublicWindowID = await self.publicWindowID(for: target.windowID)
							let unchanged = previousBinding.bindingKind == "context"
								&& previousBinding.windowID == targetPublicWindowID
								&& previousBinding.contextID == target.tabID
								&& previousBinding.explicit
								&& !previousBinding.runScoped

							if !unchanged {
								try await self.bindTarget(target, connectionID: connectionID, clientName: clientName)
							} else {
								try await self.networkMgr.setActiveWindowForCurrentConnection(target.windowID)
							}

							let binding = await self.currentBindingSummary(for: connectionID)
							let note = await self.bindContextWindowNote(runtimeWindowID: target.windowID)
							return BindContextResponse(
								binding: binding,
								changed: !unchanged,
								matchedBy: target.matchedBy,
								createdTab: target.createdTab,
								normalizedWorkingDirs: target.normalizedWorkingDirs,
								note: note
							)
						case .workingDirs:
							let target = try await self.resolveWorkingDirsBindTarget(
								workingDirs: request.workingDirs,
								windowID: request.windowID,
								createIfMissing: request.createIfMissing,
								tabName: request.tabName,
								connectionID: connectionID
							)

							let targetPublicWindowID = await self.publicWindowID(for: target.windowID)
							let unchanged = previousBinding.bindingKind == "window"
								&& previousBinding.windowID == targetPublicWindowID
								&& previousBinding.contextID == nil
								&& !previousBinding.runScoped
							if !unchanged {
								try await self.bindWindowOnly(windowID: target.windowID, connectionID: connectionID)
							} else {
								try await self.networkMgr.setActiveWindowForCurrentConnection(target.windowID)
							}

							let binding = await self.currentBindingSummary(for: connectionID)
							let note = await self.bindContextWindowNote(runtimeWindowID: target.windowID)
							return BindContextResponse(
								binding: binding,
								changed: binding != previousBinding,
								matchedBy: target.matchedBy,
								createdTab: false,
								createdWorkspace: target.createdWorkspace,
								normalizedWorkingDirs: target.normalizedWorkingDirs,
								note: note
							)
						case .windowID:
							let runtime = try await self.resolveTargetRuntime(windowID: request.windowID!)
							let windowID = runtime.windowID
							let targetPublicWindowID = await self.publicWindowID(for: windowID)
							let unchanged = previousBinding.bindingKind == "window"
								&& previousBinding.windowID == targetPublicWindowID
								&& previousBinding.contextID == nil
								&& !previousBinding.runScoped

							if !unchanged {
								try await self.bindWindowOnly(windowID: windowID, connectionID: connectionID)
							} else {
								try await self.networkMgr.setActiveWindowForCurrentConnection(windowID)
							}

							let binding = await self.currentBindingSummary(for: connectionID)
							let note = await self.bindContextWindowNote(runtimeWindowID: windowID)
							return BindContextResponse(
								binding: binding,
								changed: !unchanged,
								matchedBy: BindContextRequest.MatchKind.windowID.rawValue,
								createdTab: false,
								note: note
							)
						case .none:
							throw MCPError.invalidParams("bind_context op='bind' requires context_id, working_dirs, or window_id.")
						}

				}
			}
		)
        
		// Always register manage_workspaces so clients can route workspaces/windows.
		// Per-connection policy in ServerNetworkManager may still filter it.
        newTools.append(
            // 3️⃣ manage_workspaces ---------------------------------------------
            Tool(
                name: "manage_workspaces",
                description: """
Manage workspaces and compose-tab lifecycle in the single RepoPrompt window.

RepoPrompt runs one window. Every registered workspace stays loaded in memory; one of them is visible. Tools address workspaces by id or name, never by window. `bind_context` remains the canonical API for tab routing and context_id discovery. Legacy-compatible `list_tabs` and `select_tab` actions remain for older clients, but new integrations should prefer `bind_context`.

Actions:
• list         – Return registered workspaces in sidebar order (id, name, repoPaths, is_visible, is_available, has_running_agents, is_hidden)
• state        – Return the shell state: visible workspace, sidebar preference and the workspace list
• capture      – Write a PNG of the current window to output_path
• switch       – Make a workspace visible
• create       – Create a new workspace (optional folder_path); visible unless switch_to_created=false
• rename       – Rename a workspace
• reorder      – Set the sidebar order with workspace_ids (every workspace exactly once)
• hide         – Hide a workspace from default workspace lists without deleting it
• unhide       – Restore a hidden workspace to default workspace lists
• delete       – Remove a workspace permanently (repository files stay on disk)
• add_folder   – Add a folder to a workspace (defaults to the visible workspace)
• remove_folder – Remove a folder from a workspace (defaults to the visible workspace)
• list_tabs    – List compose tabs of the bound or visible workspace (Legacy compatibility — prefer bind_context op=list)
• select_tab   – Bind this connection to a compose tab (Legacy compatibility — prefer bind_context op=bind context_id=<id>)
• create_tab   – Create a new compose tab in the background, optionally in a workspace that is not visible
• close_tab    – Close a compose tab safely

Parameters:
- action: "list" | "state" | "capture" | "switch" | "create" | "rename" | "reorder" | "hide" | "unhide" | "delete" | "add_folder" | "remove_folder" | "list_tabs" | "select_tab" | "create_tab" | "close_tab" (required)
- workspace: string                             (required for 'switch', 'rename', 'hide', 'unhide', 'delete'; optional for 'add_folder', 'remove_folder', 'create_tab' - defaults to the visible workspace; UUID or name)
- name: string                                  (required for 'create', 'rename'; optional for 'create_tab')
- folder_path: string                           (required for 'add_folder', 'remove_folder'; optional for 'create' to initialize with a root folder; absolute path)
- workspace_ids: string[]                       (required for 'reorder'; every registered workspace UUID exactly once, in the new order)
- output_path: string                           (required for 'capture'; absolute .png path in an existing directory)
- tab: string                                   (required for 'select_tab'; optional for 'close_tab'; UUID or name)
- context_id: string                            (optional for 'close_tab'; compose-tab context UUID)
- mode: "blank" | "fork"                      (optional for 'create_tab'; default "blank")
- source_tab: string                            (optional for 'create_tab' when mode="fork"; UUID or name)
- bind: boolean                                 (optional for 'create_tab'; default true)
- focus: boolean                                (optional for 'select_tab' or 'create_tab'; if true, also makes the workspace visible and shows the tab)
- allow_active: boolean                         (optional for 'close_tab'; default false)
- window_id: integer                            (optional; the RepoPrompt window only)
- switch_to_created: boolean                    (optional for 'create'; default true; when false the workspace is registered without becoming visible)
- include_hidden: boolean                       (optional; default false. For 'list', includes hidden workspaces. For name-based 'switch'/'delete', allows hidden matches. UUID lookup remains explicit and can resolve hidden workspaces.)

Every response carries `shell`: the state after the action (visible_workspace_id, is_workspace_sidebar_collapsed, workspaces).

Hidden workspaces remain persisted/recoverable. Default 'list' and name-based 'switch'/'delete' exclude hidden workspaces unless include_hidden=true; 'hide'/'unhide' are non-destructive. Explicit UUID switch/delete can target hidden workspaces without unhiding them.

create_tab defaults to bind=true and focus=false so automation can create isolated background tabs without stealing UI focus. Pass workspace=<id|name> to work in a workspace the user is not looking at.

IMPORTANT: 'switch' and the 'focus' parameter change what the user sees, which can be disruptive to the user's workflow. Only use them when the user explicitly asks to see a workspace or tab. For background operations, use create_tab with workspace and omit focus. The 'close_tab' action refuses to close the last remaining tab, the active visible tab unless allow_active=true, or any tab with a live bound run.
""",
                inputSchema: .object(
                    properties: [
                        "action": .string(description: "Action to perform. Legacy compatibility: prefer bind_context for list_tabs/select_tab when building new integrations.", enum: ["list", "state", "capture", "switch", "create", "rename", "reorder", "hide", "unhide", "delete", "add_folder", "remove_folder", "list_tabs", "select_tab", "create_tab", "close_tab"]),
                        "workspace": .string(description: "Workspace UUID or name (required for 'switch', 'rename', 'hide', 'unhide', 'delete'; optional for 'add_folder', 'remove_folder', 'create_tab' - defaults to the visible workspace)"),
                        "name": .string(description: "Name for the workspace (required for 'create', 'rename'; optional for 'create_tab')"),
                        "folder_path": .string(description: "Absolute folder path (required for 'add_folder', 'remove_folder'; optional for 'create' to initialize with a root folder)"),
                        "workspace_ids": .array(description: "For 'reorder': every registered workspace UUID exactly once, in the new sidebar order", items: .string()),
                        "output_path": .string(description: "For 'capture': absolute .png path whose directory exists"),
						"tab": .string(description: "Compose tab UUID or name (required for 'select_tab'; optional for 'close_tab')"),
						"context_id": .string(description: "For 'close_tab': compose-tab context UUID"),
                        "mode": .string(description: "For 'create_tab': creation mode ('blank' or 'fork')"),
                        "source_tab": .string(description: "For 'create_tab' with mode='fork': source compose tab UUID or name"),
                        "bind": .boolean(description: "For 'create_tab': if true, bind this MCP connection to the new tab (default true)"),
                        "window_id": .integer(description: "Optional; the RepoPrompt window only"),
                        "focus": .boolean(description: "For 'select_tab' or 'create_tab': if true, also makes the workspace visible and shows the tab"),
                        "allow_active": .boolean(description: "For 'close_tab': allow closing the currently active visible tab"),
                        "switch_to_created": .boolean(description: "For 'create': default true; when false the workspace is registered without becoming visible."),
						"include_hidden": .boolean(description: "Default false. For list, includes hidden workspaces. For name-based switch/delete, allows hidden matches; UUID lookup remains explicit.")
                    ],
                    required: ["action"]
                ),
                annotations: .repoPromptLocalDestructive
            ) { [weak self] args -> ManageWorkspacesResponse in
                guard let self else {
                    throw MCPError.internalError("Service unavailable")
                }
                return try await self.handleManageWorkspaces(args)
            }
        )
        
        // Update the cache with the new tools
        await toolsCache.update(newTools)
    }

    /// The `manage_workspaces` handler body. Runs on the main actor: every step touches shell or window state.
    func handleManageWorkspaces(_ args: [String: Value]) async throws -> ManageWorkspacesResponse {
    guard let action = args["action"]?.stringValue?.lowercased() else {
        throw MCPError.invalidParams("Missing or invalid 'action' parameter")
    }
    for removed in ["open_in_new_window", "close_window"] where args[removed] != nil {
        throw MCPError.invalidParams("'\(removed)' is no longer supported: RepoPrompt runs a single window. Use action=switch to change the visible workspace or create_tab with workspace=<id|name> for background work.")
    }
    let requestedWindowID = args["window_id"]?.intValue
    try self.validateRequestedWindowID(requestedWindowID)
    let shellWindowID = self.windowStates.shellWindowID
    let includeHidden = args["include_hidden"]?.boolValue ?? false
    let workspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

    func requiredWorkspaceParam() throws -> String {
        guard let workspaceParam, !workspaceParam.isEmpty else {
            throw MCPError.invalidParams("Missing required 'workspace' parameter (UUID or name) for '\(action)' action.")
        }
        return workspaceParam
    }

    switch action {
    case "list":
        let snapshot = try self.shellViewModel.snapshot
        let summaries = snapshot.workspaces.filter { includeHidden || !$0.isHidden }
        return ManageWorkspacesResponse(action: "list", workspaces: summaries, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "state":
        let snapshot = try await self.dispatchShellAction(.state)
        return ManageWorkspacesResponse(action: "state", workspaces: nil, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "capture":
        guard let rawPath = args["output_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw MCPError.invalidParams("Missing required 'output_path' parameter for 'capture' action.")
        }
        let outputPath: URL
        do {
            outputPath = try WorkspaceShellActionService.validateCaptureOutputPath(rawPath)
        } catch let error as WorkspaceShellError {
            throw Self.mcpError(for: error)
        }
        let snapshot = try await self.dispatchShellAction(.capture(CapturePayload(outputPath: outputPath)))
        return ManageWorkspacesResponse(action: "capture", workspaces: nil, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "switch":
        let targetModel = try await self.resolveWorkspaceForSwitch(rawWorkspaceParam: try requiredWorkspaceParam(), includeHidden: includeHidden)
        guard !targetModel.isSystemWorkspace else {
            throw MCPError.invalidParams("\"\(targetModel.name)\" is the system workspace and cannot be selected.")
        }
        let snapshot = try await self.dispatchShellAction(.select(SelectWorkspacePayload(workspaceID: targetModel.id)))
        return ManageWorkspacesResponse(action: "switch", workspaces: nil, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "create":
        guard let workspaceName = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceName.isEmpty
        else {
            throw MCPError.invalidParams("Missing required 'name' parameter for 'create' action.")
        }
					let rawFolderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
					var initialRepoPaths: [String] = []
					if let rawFolderPath, !rawFolderPath.isEmpty {
						let expandedPath = (rawFolderPath as NSString).expandingTildeInPath
						var isDirectory: ObjCBool = false
						guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
							  isDirectory.boolValue else {
							throw MCPError.invalidParams("Folder does not exist or is not a directory: \(expandedPath)")
						}
						initialRepoPaths = [(expandedPath as NSString).standardizingPath]
					}
        let switchToCreated = args["switch_to_created"]?.boolValue ?? true
        let clientID = await self.networkMgr.currentClientIdentifier() ?? "unknown-client"
        let created = try await self.createWorkspaceInShell(
            name: workspaceName,
            repoPaths: initialRepoPaths,
            makeVisible: switchToCreated,
            clientID: clientID
        )
        let snapshot = self.currentShellSnapshot
        let summary = self.workspaceSummary(for: created.workspace, snapshot: snapshot)
        return ManageWorkspacesResponse(action: "create", workspaces: [summary], status: "ok", windowID: shellWindowID, shell: snapshot)

    case "rename":
        guard let newName = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty else {
            throw MCPError.invalidParams("Missing required 'name' parameter for 'rename' action.")
        }
        let target = try await self.resolveWorkspace(rawWorkspaceParam: try requiredWorkspaceParam(), action: "rename", includeHidden: true)
        guard !target.isSystemWorkspace else {
            throw MCPError.invalidParams("Cannot rename system workspace '\(target.name)'.")
        }
        let snapshot = try await self.dispatchShellAction(.rename(RenameWorkspacePayload(workspaceID: target.id, name: newName)))
        let summary = snapshot.workspaces.first(where: { $0.id == target.id }).map { [$0] }
        return ManageWorkspacesResponse(action: "rename", workspaces: summary, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "reorder":
        guard let rawIDs = args["workspace_ids"]?.arrayValue else {
            throw MCPError.invalidParams("Missing required 'workspace_ids' parameter (array of workspace UUIDs) for 'reorder' action.")
        }
        let ids = try rawIDs.map { raw -> UUID in
            guard let string = raw.stringValue, let id = UUID(uuidString: string) else {
                throw MCPError.invalidParams("workspace_ids must contain workspace UUID strings; got '\(raw)'.")
            }
            return id
        }
        let snapshot = try await self.dispatchShellAction(.reorder(ReorderWorkspacesPayload(workspaceIDs: ids)))
        return ManageWorkspacesResponse(action: "reorder", workspaces: snapshot.workspaces, status: "ok", windowID: shellWindowID, shell: snapshot)

    case "delete":
        let workspace = try await self.resolveWorkspaceForDelete(rawWorkspaceParam: try requiredWorkspaceParam(), includeHidden: includeHidden)
        guard !workspace.isSystemWorkspace else {
            throw MCPError.invalidParams("Cannot delete system workspace '\(workspace.name)'.")
        }
        let clientID = await self.networkMgr.currentClientIdentifier() ?? "unknown-client"
        let service = try self.requireShellActionService()
        do {
            let snapshot = try await service.dispatch(.remove(RemoveWorkspacePayload(workspaceID: workspace.id, source: .tool(clientID: clientID))))
            return ManageWorkspacesResponse(action: "delete", workspaces: nil, status: "ok", windowID: shellWindowID, shell: snapshot)
        } catch WorkspaceShellError.approvalDenied {
            throw MCPError.invalidRequest("Workspace deletion was denied by the user.")
        } catch WorkspaceShellError.cancelled {
            throw MCPError.invalidRequest("Workspace removal was cancelled: \"\(workspace.name)\" has a running agent and the user kept it (status: cancelled).")
        } catch let error as WorkspaceShellError {
            throw Self.mcpError(for: error)
        }

				case "hide", "unhide":
					let shouldHide = action == "hide"
					let resolvedWorkspace = try await self.resolveWorkspaceForHiddenMutation(rawWorkspaceParam: try requiredWorkspaceParam(), hidden: shouldHide)
					guard !resolvedWorkspace.isSystemWorkspace else {
						throw MCPError.invalidParams("Cannot \(action) system workspace '\(resolvedWorkspace.name)'.")
					}
					let writer = try self.catalogWriter(for: resolvedWorkspace.id)
					let updatedWorkspace = try await writer.workspaceManager.setWorkspaceHiddenFromSnapshot(resolvedWorkspace, hidden: shouldHide)
					await self.propagateCatalogWrite(from: writer)
					let snapshot = self.currentShellSnapshot
					let summary = self.workspaceSummary(for: updatedWorkspace, snapshot: snapshot)
					return ManageWorkspacesResponse(action: action, workspaces: [summary], status: "ok", windowID: shellWindowID, shell: snapshot)

    case "add_folder":
        guard let folderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folderPath.isEmpty
        else {
            throw MCPError.invalidParams("Missing required 'folder_path' parameter for 'add_folder' action.")
        }
        let folderURL = URL(fileURLWithPath: folderPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPError.invalidParams("Folder does not exist or is not a directory: \(folderPath)")
        }
        let target = try await self.resolveFolderMutationTarget(rawWorkspaceParam: workspaceParam, windowID: requestedWindowID, action: "add_folder")
        try Self.validateAddFolderWorkspace(target.workspace)
        let clientID = await self.networkMgr.currentClientIdentifier() ?? "unknown-client"
        let approvalResult = await WorkspaceApprovalManager.shared.requestAddFolderApproval(
            clientID: clientID,
            folderPath: folderPath,
            workspaceName: target.workspace.name,
            workspaceID: target.workspace.id,
            windowID: self.publicWindowID(for: target.runtime.windowID)
        )
        guard approvalResult.isApproved else {
            throw MCPError.invalidRequest("Folder addition was denied by the user.")
        }
        do {
            try await target.runtime.workspaceManager.addFolder(folderURL, to: target.workspace)
        } catch {
            if let addError = error as? WorkspaceManagerViewModel.AddFolderError {
                throw MCPError.invalidParams(addError.agentMessage)
            }
            throw MCPError.internalError("Failed to add folder: \(error.localizedDescription)")
        }
        await self.propagateCatalogWrite(from: target.runtime)
        let snapshot = self.currentShellSnapshot
        let updated = target.runtime.workspaceManager.workspace(withID: target.workspace.id) ?? target.workspace
        return ManageWorkspacesResponse(action: "add_folder", workspaces: [self.workspaceSummary(for: updated, snapshot: snapshot)], status: "ok", windowID: shellWindowID, shell: snapshot)

    case "remove_folder":
        guard let folderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folderPath.isEmpty
        else {
            throw MCPError.invalidParams("Missing required 'folder_path' parameter for 'remove_folder' action.")
        }
        let target = try await self.resolveFolderMutationTarget(rawWorkspaceParam: workspaceParam, windowID: requestedWindowID, action: "remove_folder")
        let normalizedPath = (folderPath as NSString).standardizingPath
        let folderInWorkspace = target.workspace.repoPaths.contains { path in
            (path as NSString).standardizingPath.caseInsensitiveCompare(normalizedPath) == .orderedSame
        }
        guard folderInWorkspace else {
            throw MCPError.invalidParams("Folder '\(folderPath)' is not in workspace '\(target.workspace.name)'")
        }
        let clientID = await self.networkMgr.currentClientIdentifier() ?? "unknown-client"
        let approvalResult = await WorkspaceApprovalManager.shared.requestRemoveFolderApproval(
            clientID: clientID,
            folderPath: folderPath,
            workspaceName: target.workspace.name,
            workspaceID: target.workspace.id,
            windowID: self.publicWindowID(for: target.runtime.windowID)
        )
        guard approvalResult.isApproved else {
            throw MCPError.invalidRequest("Folder removal was denied by the user.")
        }
        await target.runtime.workspaceManager.removeFolder(folderPath, from: target.workspace)
        await self.propagateCatalogWrite(from: target.runtime)
        let snapshot = self.currentShellSnapshot
        let updated = target.runtime.workspaceManager.workspace(withID: target.workspace.id) ?? target.workspace
        return ManageWorkspacesResponse(action: "remove_folder", workspaces: [self.workspaceSummary(for: updated, snapshot: snapshot)], status: "ok", windowID: shellWindowID, shell: snapshot)

    case "list_tabs":
        let targetWindow = try await self.resolveTargetRuntime(windowID: requestedWindowID)
        let connectionID = await self.networkMgr.currentConnectionUUID()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace loaded. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        let activeTabID = workspace.activeComposeTabID
        let boundTabID = targetWindow.mcpServer.boundTabID(forConnection: connectionID)
        let windowID = self.publicWindowID(for: targetWindow.windowID)
        let summaries = workspace.composeTabs.map {
            self.makeComposeTabSummary(tab: $0, workspace: workspace, windowID: windowID, activeTabID: activeTabID, boundTabID: boundTabID)
        }
        return ManageWorkspacesResponse(action: "list_tabs", workspaces: nil, tabs: summaries, status: "ok", windowID: shellWindowID, shell: self.currentShellSnapshot)

    case "select_tab":
        guard let rawTabParam = args["tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTabParam.isEmpty
        else {
            throw MCPError.invalidParams("Missing required 'tab' parameter (UUID or name) for 'select_tab' action.")
        }
        let targetWindow = try await self.resolveTargetRuntime(windowID: requestedWindowID)
        let shouldFocus = args["focus"]?.boolValue ?? false
        let connectionID = await self.networkMgr.currentConnectionUUID()
        let clientName = await self.networkMgr.currentClientIdentifier()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace loaded. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        guard let connectionID else {
            throw MCPError.internalError("No active connection context")
        }
        let tab = try self.resolveComposeTab(rawTabParam: rawTabParam, tabs: workspace.composeTabs)
        try await self.networkMgr.setActiveWindowForCurrentConnection(targetWindow.windowID)
        try targetWindow.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: clientName,
            tabID: tab.id,
            workspaceID: workspace.id,
            windowID: targetWindow.windowID
        )
        if shouldFocus {
            if self.windowStates.shell != nil {
                _ = try await self.dispatchShellAction(.select(SelectWorkspacePayload(workspaceID: workspace.id)))
            }
            await targetWindow.promptManager.switchComposeTab(tab.id)
        }
        return ManageWorkspacesResponse(action: "select_tab", workspaces: nil, status: "ok", windowID: shellWindowID, shell: self.currentShellSnapshot)

    case "create_tab":
        let targetWindow: WindowState
        if let workspaceParam, !workspaceParam.isEmpty {
            let resolved = try await self.resolveWorkspace(rawWorkspaceParam: workspaceParam, action: "create_tab", includeHidden: true)
            guard !resolved.isSystemWorkspace else {
                throw MCPError.invalidParams("\"\(resolved.name)\" is the system workspace and cannot hold compose tabs.")
            }
            targetWindow = try await self.retainedRuntime(for: resolved)
        } else {
            targetWindow = try await self.resolveTargetRuntime(windowID: requestedWindowID)
            if self.windowStates.shell != nil, targetWindow.workspaceManager.activeWorkspace?.isSystemWorkspace != false {
                throw MCPError.invalidRequest("No workspace is registered. Create one with action=create first.")
            }
        }
        let connectionID = await self.networkMgr.currentConnectionUUID()
        let clientName = await self.networkMgr.currentClientIdentifier()
        let mode = args["mode"]?.stringValue?.lowercased() ?? "blank"
        let shouldBind = args["bind"]?.boolValue ?? true
        let shouldFocus = args["focus"]?.boolValue ?? false
        let requestedName = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace loaded. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        let tabs = workspace.composeTabs
        let activeTabID = workspace.activeComposeTabID
        let boundTabID = targetWindow.mcpServer.boundTabID(forConnection: connectionID)

        let newTab: ComposeTabState
        switch mode {
        case "blank":
            guard let created = await targetWindow.promptManager.createBackgroundComposeTab(strategy: .blank, name: requestedName) else {
                throw MCPError.internalError("Failed to create compose tab")
            }
            newTab = created
        case "fork":
            let sourceRaw = args["source_tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceTab: ComposeTabState
            if let sourceRaw, !sourceRaw.isEmpty {
                sourceTab = try self.resolveComposeTab(rawTabParam: sourceRaw, tabs: tabs)
            } else if let boundTabID, let boundTab = tabs.first(where: { $0.id == boundTabID }) {
                sourceTab = boundTab
            } else if let activeTabID, let activeTab = tabs.first(where: { $0.id == activeTabID }) {
                sourceTab = activeTab
            } else {
                throw MCPError.invalidParams("create_tab mode='fork' requires a source tab or an active/bound tab")
            }
            guard let created = await targetWindow.promptManager.createBackgroundForkComposeTab(sourceTabID: sourceTab.id, named: requestedName) else {
                throw MCPError.internalError("Failed to fork compose tab")
            }
            newTab = created
        default:
            throw MCPError.invalidParams("Unsupported create_tab mode '\(mode)'. Use 'blank' or 'fork'.")
        }

        try await self.networkMgr.setActiveWindowForCurrentConnection(targetWindow.windowID)
        if shouldBind, let connectionID {
            try targetWindow.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: newTab.id,
                workspaceID: workspace.id,
                windowID: targetWindow.windowID
            )
        }
        if shouldFocus {
            if self.windowStates.shell != nil {
                _ = try await self.dispatchShellAction(.select(SelectWorkspacePayload(workspaceID: workspace.id)))
            }
            await targetWindow.promptManager.switchComposeTab(newTab.id)
        }
        let summary = self.makeComposeTabSummary(
            tab: newTab,
            workspace: workspace,
            windowID: self.publicWindowID(for: targetWindow.windowID),
            activeTabID: shouldFocus ? newTab.id : activeTabID,
            boundTabID: shouldBind ? newTab.id : boundTabID
        )
        return ManageWorkspacesResponse(action: "create_tab", workspaces: nil, tabs: [summary], status: "ok", windowID: shellWindowID, shell: self.currentShellSnapshot)

    case "close_tab":
        let rawTabParam = args["tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextID = try Self.parseContextID(args["context_id"], action: "close_tab")
        let targetWindow = try await self.resolveTargetRuntime(windowID: requestedWindowID)
        let allowActive = args["allow_active"]?.boolValue ?? false
        let connectionID = await self.networkMgr.currentConnectionUUID()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace, !workspace.composeTabs.isEmpty else {
            throw MCPError.invalidParams("No active workspace with compose tabs loaded. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        let tabs = workspace.composeTabs
        let activeTabID = workspace.activeComposeTabID
        let boundTabID = targetWindow.mcpServer.boundTabID(forConnection: connectionID)
        let tab = try self.resolveComposeTab(rawTabParam: rawTabParam, contextID: contextID, tabs: tabs, action: "close_tab")
        guard tabs.count > 1 else {
            throw MCPError.invalidParams("Cannot close the last remaining compose tab.")
        }
        if activeTabID == tab.id && !allowActive {
            throw MCPError.invalidParams("Refusing to close the active visible tab. Pass allow_active=true to close it explicitly.")
        }
        let liveRunIDs = targetWindow.mcpServer.liveRunIDsBound(toTabID: tab.id)
        if !liveRunIDs.isEmpty {
            let joined = liveRunIDs.map(\.uuidString).joined(separator: ", ")
            throw MCPError.invalidParams("Refusing to close tab '\(tab.name)' because it has live bound runs: \(joined)")
        }
        let summary = self.makeComposeTabSummary(
            tab: tab,
            workspace: workspace,
            windowID: self.publicWindowID(for: targetWindow.windowID),
            activeTabID: activeTabID,
            boundTabID: boundTabID
        )
        await targetWindow.promptManager.closeComposeTab(tab.id)
        return ManageWorkspacesResponse(action: "close_tab", workspaces: nil, tabs: [summary], status: "ok", windowID: shellWindowID, shell: self.currentShellSnapshot)

    default:
        throw MCPError.invalidParams("Unsupported action '\(action)'. Use 'list', 'state', 'capture', 'switch', 'create', 'rename', 'reorder', 'hide', 'unhide', 'delete', 'add_folder', 'remove_folder', 'list_tabs', 'select_tab', 'create_tab', or 'close_tab'.")
    }
    }
    
    // ---------------------------------------------------------------------
    // MARK: Tools
    // ---------------------------------------------------------------------
    nonisolated var tools: [Tool] {
        get async {
            await toolsCache.get()
        }
    }
}
