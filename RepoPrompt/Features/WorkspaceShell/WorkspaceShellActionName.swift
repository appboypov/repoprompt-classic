import Foundation

/// Stable names of the workspace shell's named actions.
/// Every dispatcher (sidebar, keyboard, deep link, MCP, CLI) reaches a handler through one of these.
enum WorkspaceShellActionName: String, CaseIterable, Sendable {
	case select = "workspace_shell.select"
	case add = "workspace_shell.add"
	case rename = "workspace_shell.rename"
	case reorder = "workspace_shell.reorder"
	case remove = "workspace_shell.remove"
	case setSidebarCollapsed = "workspace_shell.set_sidebar_collapsed"
	case openRoute = "workspace_shell.open_route"
	case capture = "workspace_shell.capture"
	case state = "workspace_shell.state"

	/// Actions that change shell or catalog state and therefore run serialized.
	var isMutating: Bool {
		switch self {
		case .select, .add, .rename, .reorder, .remove, .setSidebarCollapsed, .openRoute:
			return true
		case .capture, .state:
			return false
		}
	}
}
