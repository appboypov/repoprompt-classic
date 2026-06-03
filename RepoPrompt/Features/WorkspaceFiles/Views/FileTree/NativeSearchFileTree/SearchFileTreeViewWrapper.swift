import SwiftUI
import AppKit

/// Bridges the AppKit‐based `SearchFileTreeViewController` into SwiftUI.
struct SearchFileTreeViewWrapper: NSViewControllerRepresentable {
    @ObservedObject var searchViewModel: SearchFileTreeViewModel

    // MARK: - NSViewControllerRepresentable
    func makeNSViewController(context: Context) -> SearchFileTreeViewController {
        let vc = SearchFileTreeViewController()
        vc.searchViewModel = searchViewModel
        return vc
    }

    func updateNSViewController(_ nsViewController: SearchFileTreeViewController, context: Context) {
        if nsViewController.searchViewModel !== searchViewModel {
            nsViewController.searchViewModel = searchViewModel
        }
        // IMPORTANT:
        // Do NOT call outlineView.reloadData() (or any layout-triggering work) from here.
        // SwiftUI can call updateNSViewController during its own constraints/layout pass.
        // Calling reloadData() here causes re-entrant layout invalidation leading to
        // infinite layout loops (EXC_BREAKPOINT in NSHostingView._layoutSubtreeWithOldSize).
        // The controller already observes vm.$rootFolders and applies snapshots itself.
    }

    static func dismantleNSViewController(_ nsViewController: SearchFileTreeViewController, coordinator: ()) {
        nsViewController.cleanupBindings()
    }
}