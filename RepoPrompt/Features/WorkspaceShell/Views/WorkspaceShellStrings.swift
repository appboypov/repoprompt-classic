import Foundation

/// Every user-facing string of the workspace shell. The project has no localization catalog, so one file holds them.
enum WorkspaceShellStrings {
	static let sidebarTitle = "Workspaces"
	static let addWorkspace = "Add workspace"
	static let rename = "Rename"
	static let remove = "Remove"
	static let collapseSidebar = "Collapse sidebar"
	static let expandSidebar = "Expand sidebar"

	static let unavailable = "Unavailable"
	static let runningAgent = "Agent running"
	static let unavailableHelp = "A folder of this workspace is missing on disk"
	static let runningAgentHelp = "An agent is running in this workspace"

	static let emptyTitle = "No workspaces"
	static let emptyBody = "Add a folder to start working; every workspace you add stays loaded until you remove it."

	static let preparing = "Preparing"

	static let removeTitle = "Remove workspace"
	static let removeBody = "The workspace and its saved state are removed; repository files stay on disk."
	static let removeRunningBody = "An agent is still running here. Removing stops it first."
	static let cancel = "Cancel"
	static let stopAndRemove = "Stop and remove"

	static let add = "Add"
	static let save = "Save"
	static let addNamePlaceholder = "Workspace name"
	static let chooseFolder = "Choose folder"
	static let chooseFolderMessage = "Pick the first folder of the new workspace"
	static let noFolderChosen = "No folder chosen"
	static let renameTitle = "Rename Workspace"
	static let renamePlaceholder = "New name"

	static func folderCount(_ count: Int) -> String {
		count == 1 ? "1 folder" : "\(count) folders"
	}

	static func rowTooltip(name: String, rootCount: Int) -> String {
		"\(name) - \(folderCount(rootCount))"
	}

	static func removeBody(workspaceName: String) -> String {
		"\"\(workspaceName)\" is removed from the sidebar and its saved state is deleted; repository files stay on disk."
	}

	static func preparing(workspaceName: String) -> String {
		"\(preparing) \(workspaceName)"
	}
}
