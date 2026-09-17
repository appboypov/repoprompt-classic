import SwiftUI

/// What the content host shows when the catalog is empty.
struct WorkspaceEmptyStateView: View {
	let onAdd: () -> Void

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: "square.stack.3d.up")
				.font(.system(size: 36, weight: .light))
				.foregroundColor(.secondary)
			Text(WorkspaceShellStrings.emptyTitle)
				.font(fontScale.preset.swiftUIFont(sizeAtNormal: 18, weight: .semibold))
			Text(WorkspaceShellStrings.emptyBody)
				.font(fontScale.preset.swiftUIFont(sizeAtNormal: 13, weight: .regular))
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 360)
			Button(WorkspaceShellStrings.addWorkspace, action: onAdd)
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.keyboardShortcut(.defaultAction)
				.padding(.top, 4)
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

#Preview("Empty state") {
	WorkspaceEmptyStateView(onAdd: {})
		.frame(width: 640, height: 400)
}
