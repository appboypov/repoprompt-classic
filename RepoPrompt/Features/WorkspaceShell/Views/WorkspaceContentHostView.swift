import SwiftUI
import AppKit

/// Keeps every prepared runtime's hosting view mounted in one container and shows exactly one.
/// Each runtime is its own `NSHostingController` view graph, so hidden runtimes take no SwiftUI
/// updates and a switch is a hidden flag flip. Views are built as runtimes finish preparing.
struct WorkspaceContentHostView: NSViewRepresentable {
	@ObservedObject var shellViewModel: WorkspaceShellViewModel
	let onAdd: () -> Void

	func makeNSView(context: Context) -> NSView {
		let container = ContainerView(frame: .zero)
		container.autoresizesSubviews = true
		return container
	}

	/// The container fills whatever the shell proposes. Without this, SwiftUI measures the
	/// platform view by running Auto Layout over every mounted runtime's subtree on every pass.
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
	}

	/// Frame-driven container: reports no intrinsic or fitting size, so nothing walks its subtree.
	private final class ContainerView: NSView {
		override var intrinsicContentSize: NSSize {
			NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
		}
		override var fittingSize: NSSize { bounds.size }
	}

	func updateNSView(_ container: NSView, context: Context) {
		let coordinator = context.coordinator
		let loaded = shellViewModel.snapshot.workspaces.compactMap { shellViewModel.runtime(for: $0.id) }
		let loadedIDs = Set(loaded.map { $0.windowID })

		for (windowID, view) in coordinator.mountedRuntimeViews where !loadedIDs.contains(windowID) {
			view.removeFromSuperview()
			coordinator.mountedRuntimeViews[windowID] = nil
		}
		for runtime in loaded where coordinator.mountedRuntimeViews[runtime.windowID] == nil {
			let view = runtime.hostingController.view
			view.isHidden = true
			mount(view, in: container)
			coordinator.mountedRuntimeViews[runtime.windowID] = view
		}

		let content = resolveContent()
		let shownRuntimeID: Int?
		if case .runtime(let runtime) = content {
			shownRuntimeID = runtime.windowID
		} else {
			shownRuntimeID = nil
		}
		for (windowID, view) in coordinator.mountedRuntimeViews {
			view.isHidden = windowID != shownRuntimeID
		}

		let placeholderKey: String?
		switch content {
		case .runtime: placeholderKey = nil
		case .preparing(let name): placeholderKey = "preparing-\(name)"
		case .empty: placeholderKey = "empty"
		}
		guard coordinator.placeholderKey != placeholderKey else { return }
		coordinator.placeholderKey = placeholderKey
		coordinator.placeholder?.view.removeFromSuperview()
		coordinator.placeholder = nil
		switch content {
		case .runtime:
			break
		case .preparing(let name):
			mountPlaceholder(WorkspacePreparingView(name: name), coordinator: coordinator, in: container)
		case .empty:
			mountPlaceholder(WorkspaceEmptyStateView(onAdd: onAdd), coordinator: coordinator, in: container)
		}
	}

	private func mount(_ view: NSView, in container: NSView) {
		view.frame = container.bounds
		view.autoresizingMask = [.width, .height]
		container.addSubview(view)
	}

	/// Placeholders draw their own window background: the hosting view is transparent and the
	/// runtimes below it are hidden, so nothing else paints the content area.
	private func mountPlaceholder<Content: View>(_ content: Content, coordinator: Coordinator, in container: NSView) {
		let placeholder = NSHostingController(rootView: AnyView(content.background(Color(nsColor: .windowBackgroundColor))))
		coordinator.placeholder = placeholder
		mount(placeholder.view, in: container)
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	final class Coordinator {
		var mountedRuntimeViews: [Int: NSView] = [:]
		var placeholderKey: String?
		/// Keeps the placeholder controller alive while its view is mounted.
		var placeholder: NSHostingController<AnyView>?
	}

	private enum Content {
		case runtime(WindowState)
		case preparing(String)
		case empty
	}

	private func resolveContent() -> Content {
		guard let visibleID = shellViewModel.snapshot.visibleWorkspaceID else {
			return .empty
		}
		if let runtime = shellViewModel.runtime(for: visibleID), !shellViewModel.preparingWorkspaceIDs.contains(visibleID) {
			return .runtime(runtime)
		}
		let name = shellViewModel.snapshot.workspaces.first(where: { $0.id == visibleID })?.name ?? ""
		return .preparing(name)
	}
}
