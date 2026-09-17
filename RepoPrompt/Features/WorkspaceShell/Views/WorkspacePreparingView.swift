import SwiftUI

/// Shown by the content host while a selected runtime is still loading its first state.
struct WorkspacePreparingView: View {
	let name: String

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		VStack(spacing: 12) {
			ProgressView()
				.controlSize(.regular)
			Text(WorkspaceShellStrings.preparing(workspaceName: name))
				.font(fontScale.preset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
				.foregroundColor(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.accessibilityElement(children: .combine)
	}
}

#Preview("Preparing") {
	WorkspacePreparingView(name: "Shared Kernel Library")
		.frame(width: 640, height: 400)
}
