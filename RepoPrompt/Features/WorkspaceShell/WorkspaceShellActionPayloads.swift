import Foundation

/// Who asked for a shell mutation. Decides which confirmation surface appears.
enum WorkspaceShellRequestSource: Equatable, Sendable {
	/// The desktop user, through the sidebar, menus or keyboard.
	case user
	/// An MCP or CLI client, identified by its connection.
	case tool(clientID: String)
}

struct SelectWorkspacePayload: Equatable, Sendable {
	let workspaceID: UUID
}

struct AddWorkspacePayload: Equatable, Sendable {
	let name: String
	let folderPath: String?
	let makeVisible: Bool
	let source: WorkspaceShellRequestSource
}

struct RenameWorkspacePayload: Equatable, Sendable {
	let workspaceID: UUID
	let name: String
}

struct ReorderWorkspacesPayload: Equatable, Sendable {
	let workspaceIDs: [UUID]
}

struct RemoveWorkspacePayload: Equatable, Sendable {
	let workspaceID: UUID
	let source: WorkspaceShellRequestSource
}

struct SetSidebarCollapsedPayload: Equatable, Sendable {
	let isCollapsed: Bool
}

enum OpenRouteTarget: Equatable, Sendable {
	case workspace(id: UUID?, name: String?)
	case agentSession(AgentSessionDeepLinkRoute)
}

struct OpenRoutePayload: Equatable, Sendable {
	let target: OpenRouteTarget
}

struct CapturePayload: Equatable, Sendable {
	let outputPath: URL
}

/// Typed argument of one shell action. One case per `WorkspaceShellActionName`.
enum WorkspaceShellActionPayload: Equatable, Sendable {
	case select(SelectWorkspacePayload)
	case add(AddWorkspacePayload)
	case rename(RenameWorkspacePayload)
	case reorder(ReorderWorkspacesPayload)
	case remove(RemoveWorkspacePayload)
	case setSidebarCollapsed(SetSidebarCollapsedPayload)
	case openRoute(OpenRoutePayload)
	case capture(CapturePayload)
	case state

	var actionName: WorkspaceShellActionName {
		switch self {
		case .select: return .select
		case .add: return .add
		case .rename: return .rename
		case .reorder: return .reorder
		case .remove: return .remove
		case .setSidebarCollapsed: return .setSidebarCollapsed
		case .openRoute: return .openRoute
		case .capture: return .capture
		case .state: return .state
		}
	}
}
