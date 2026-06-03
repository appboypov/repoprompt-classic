import SwiftUI
import AppKit

struct FileTreeContainerViewWrapper: NSViewControllerRepresentable {
	let windowID: Int
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var workspaceManager: WorkspaceManagerViewModel
	@ObservedObject var searchViewModel: SearchFileTreeViewModel

	func makeNSViewController(context: Context) -> FileTreeContainerViewController {
		let viewController = FileTreeContainerViewController()
		viewController.windowID = windowID
		viewController.fileManager = fileManager
		viewController.workspaceManager = workspaceManager
		viewController.searchViewModel = searchViewModel
		return viewController
	}

	func updateNSViewController(_ nsViewController: FileTreeContainerViewController, context: Context) {
		if nsViewController.windowID != windowID {
			nsViewController.windowID = windowID
		}
		if nsViewController.fileManager !== fileManager {
			nsViewController.fileManager = fileManager
		}
		if nsViewController.workspaceManager !== workspaceManager {
			nsViewController.workspaceManager = workspaceManager
		}
		if nsViewController.searchViewModel !== searchViewModel {
			nsViewController.searchViewModel = searchViewModel
		}
	}

	static func dismantleNSViewController(_ nsViewController: FileTreeContainerViewController, coordinator: ()) {
		nsViewController.cleanupBindings()
	}
}
