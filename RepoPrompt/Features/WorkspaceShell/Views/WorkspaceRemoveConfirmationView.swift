import SwiftUI

/// The one removal choice, shown by the sidebar for user removals and by the approval overlay for tool removals.
struct WorkspaceRemoveConfirmationView: View {
	let workspaceName: String
	let hasRunningAgents: Bool
	let onConfirm: () -> Void
	let onCancel: () -> Void

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 8) {
				Text(WorkspaceShellStrings.removeTitle)
					.font(fontScale.preset.swiftUIFont(sizeAtNormal: 15, weight: .semibold))
				Text(WorkspaceShellStrings.removeBody(workspaceName: workspaceName))
					.font(fontScale.preset.swiftUIFont(sizeAtNormal: 13, weight: .regular))
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if hasRunningAgents {
					HStack(alignment: .top, spacing: 6) {
						WorkspaceBadge(kind: .runningAgent, size: .dot)
							.padding(.top, 5)
						Text(WorkspaceShellStrings.removeRunningBody)
							.font(fontScale.preset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}

			HStack(spacing: 12) {
				Button(action: onCancel) {
					Text(WorkspaceShellStrings.cancel)
						.font(.subheadline.weight(.medium))
						.frame(maxWidth: .infinity)
						.frame(height: 40)
				}
				.buttonStyle(WorkspaceApprovalDenyButtonStyle())
				.keyboardShortcut(.cancelAction)

				Button(action: onConfirm) {
					Text(hasRunningAgents ? WorkspaceShellStrings.stopAndRemove : WorkspaceShellStrings.remove)
						.font(.subheadline.weight(.medium))
						.frame(maxWidth: .infinity)
						.frame(height: 40)
				}
				.buttonStyle(WorkspaceApprovalAllowButtonStyle(riskLevel: hasRunningAgents ? .high : .medium))
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 400)
	}
}

#Preview("Remove idle") {
	WorkspaceRemoveConfirmationView(workspaceName: "Shared Kernel Library", hasRunningAgents: false, onConfirm: {}, onCancel: {})
}

#Preview("Remove with running agent") {
	WorkspaceRemoveConfirmationView(workspaceName: "Agents", hasRunningAgents: true, onConfirm: {}, onCancel: {})
}
