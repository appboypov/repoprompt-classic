import SwiftUI

/// File-menu items that operate on the workspace the shell shows.
struct WorkspaceCommands: Commands {
	@ObservedObject var windowStatesManager: WindowStatesManager

	var body: some Commands {
		// Insert immediately after the system "Save" item.
		CommandGroup(after: .saveItem) {
			Button("Save Workspace") {
				windowStatesManager.visibleWindowState?.workspaceManager.pollAndSaveState()
			}
			.keyboardShortcut("s", modifiers: .command)
		}
	}
}
