import SwiftUI

/// Names a new workspace and optionally picks its first folder. Returns through `onAdd`.
struct WorkspaceAddSheet: View {
	let onAdd: (_ name: String, _ folderPath: String?) -> Void
	let onCancel: () -> Void

	@State private var name = ""
	@State private var folderPath: String?
	@ObservedObject private var fontScale = FontScaleManager.shared

	private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(WorkspaceShellStrings.addWorkspace)
				.font(fontScale.preset.headlineFont)
			TextField(WorkspaceShellStrings.addNamePlaceholder, text: $name)
				.textFieldStyle(RoundedBorderTextFieldStyle())
			HStack(spacing: 8) {
				Button(WorkspaceShellStrings.chooseFolder) {
					Task { @MainActor in
						guard let url = await OpenPanelService.shared.pickFolder(
							title: WorkspaceShellStrings.addWorkspace,
							message: WorkspaceShellStrings.chooseFolderMessage
						) else { return }
						folderPath = (url.path as NSString).standardizingPath
						if trimmedName.isEmpty {
							name = url.lastPathComponent
						}
					}
				}
				Text(folderPath ?? WorkspaceShellStrings.noFolderChosen)
					.font(fontScale.preset.captionFont)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			HStack {
				Spacer()
				Button(WorkspaceShellStrings.cancel, action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button(WorkspaceShellStrings.add) {
					onAdd(trimmedName, folderPath)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(trimmedName.isEmpty)
			}
		}
		.padding()
		.frame(width: fontScale.preset.scaledClamped(420, max: 520))
	}
}

/// Renames one workspace. Returns the trimmed name through `onSave`.
struct WorkspaceRenameSheet: View {
	let currentName: String
	let onSave: (String) -> Void
	let onCancel: () -> Void

	@State private var name: String
	@ObservedObject private var fontScale = FontScaleManager.shared

	init(currentName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
		self.currentName = currentName
		self.onSave = onSave
		self.onCancel = onCancel
		_name = State(initialValue: currentName)
	}

	private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

	var body: some View {
		VStack(spacing: 16) {
			Text(WorkspaceShellStrings.renameTitle)
				.font(fontScale.preset.headlineFont)
			TextField(WorkspaceShellStrings.renamePlaceholder, text: $name)
				.textFieldStyle(RoundedBorderTextFieldStyle())
				.frame(minWidth: fontScale.preset.scaledMetric(200))
			HStack {
				Spacer()
				Button(WorkspaceShellStrings.cancel, action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button(WorkspaceShellStrings.save) {
					onSave(trimmedName)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(trimmedName.isEmpty)
			}
		}
		.padding()
		.frame(width: fontScale.preset.scaledClamped(360, max: 460))
	}
}
