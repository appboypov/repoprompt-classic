import Foundation
import SwiftUI

enum WorkspaceSwitchResult {
	case switched
	case cancelled(String)
	case blocked(String)

	var didSwitch: Bool {
		if case .switched = self { return true }
		return false
	}

	var message: String? {
		switch self {
		case .switched:
			return nil
		case .cancelled(let message), .blocked(let message):
			return message
		}
	}
}

struct WorkspaceSwitchSessionItem: Hashable {
	let id: String
	let count: Int
	let singularLabel: String
	let pluralLabel: String

	func formattedCount() -> String {
		let label = count == 1 ? singularLabel : pluralLabel
		return "\(count) \(label)"
	}
}

struct WorkspaceSwitchSessionSnapshot {
	let items: [WorkspaceSwitchSessionItem]

	var hasActiveSessions: Bool {
		!items.isEmpty
	}
}

struct WorkspaceSwitchConfirmation: Identifiable {
	let id = UUID()
	let targetWorkspaceName: String
	let items: [WorkspaceSwitchSessionItem]

	private func summaryText() -> String {
		let parts = items
			.filter { $0.count > 0 }
			.map { $0.formattedCount() }
		return parts.joined(separator: " and ")
	}

	var message: String {
		let summary = summaryText()
		if summary.isEmpty {
			return "Switching workspaces will terminate any running sessions. Do you want to continue?"
		}
		return "Switching to \"\(targetWorkspaceName)\" will terminate \(summary). Do you want to continue?"
	}

	var cancelMessage: String {
		let summary = summaryText()
		if summary.isEmpty {
			return "Workspace switch was cancelled by the user."
		}
		return "Workspace switch cancelled. The current workspace has \(summary). Confirm termination to proceed."
	}
}

struct WorkspaceSwitchOverlayState: Equatable {
	let targetWorkspaceName: String
	let startedAt: Date
}

// MARK: - View Modifier for Switch Confirmation Alert
// Extracted to reduce type-checking complexity in ContentView

struct WorkspaceSwitchConfirmationModifier: ViewModifier {
	@ObservedObject var workspaceManager: WorkspaceManagerViewModel

	private var isPresented: Binding<Bool> {
		Binding(
			get: { workspaceManager.pendingSwitchConfirmation != nil },
			set: { newValue in
				if !newValue && workspaceManager.hasPendingSwitchConfirmation {
					workspaceManager.resolveSwitchConfirmation(allow: false)
				}
			}
		)
	}

	func body(content: Content) -> some View {
		content
			.alert(
				"Switch Workspace?",
				isPresented: isPresented,
				presenting: workspaceManager.pendingSwitchConfirmation
			) { _ in
				Button("Switch and End Sessions", role: .destructive) {
					workspaceManager.resolveSwitchConfirmation(allow: true)
				}
				Button("Cancel", role: .cancel) {
					workspaceManager.resolveSwitchConfirmation(allow: false)
				}
			} message: { confirmation in
				Text(confirmation.message)
			}
	}
}

extension View {
	func workspaceSwitchConfirmation(manager: WorkspaceManagerViewModel) -> some View {
		modifier(WorkspaceSwitchConfirmationModifier(workspaceManager: manager))
	}
}
