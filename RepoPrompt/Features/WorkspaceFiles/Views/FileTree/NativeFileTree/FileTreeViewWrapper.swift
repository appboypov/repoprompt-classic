import SwiftUI
import AppKit

struct FileTreeViewWrapper: NSViewControllerRepresentable {
	let windowID: Int
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var workspaceManager: WorkspaceManagerViewModel
	
	func makeNSViewController(context: Context) -> FileTreeViewController {
		// Create programmatically instead of using a nib
		let viewController = FileTreeViewController()
		viewController.windowID = windowID
		viewController.fileManager = fileManager
		viewController.workspaceManager = workspaceManager
		// Don't call setupBindings here - it will be called in viewDidLoad
		return viewController
	}
	
	func updateNSViewController(_ nsViewController: FileTreeViewController, context: Context) {
		// If the manager reference changes, re-bind; snapshot pipeline will reload as needed
		if nsViewController.fileManager !== fileManager {
			nsViewController.cleanupBindings()
			nsViewController.fileManager = fileManager
			if nsViewController.isViewLoaded {
				nsViewController.setupBindings()
			}
		}

		
		// ❌ Remove the unconditional reloadData():
		// if nsViewController.isViewLoaded {
		//     nsViewController.outlineView.reloadData()
		// }
	}
	
	// Called when the view disappears
	static func dismantleNSViewController(_ nsViewController: FileTreeViewController, coordinator: Coordinator) {
		nsViewController.cleanupBindings()
	}
}
