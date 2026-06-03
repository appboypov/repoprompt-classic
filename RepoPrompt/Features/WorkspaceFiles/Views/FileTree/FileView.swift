import SwiftUI

/// A SwiftUI view displaying a single file in the file tree, with no direct fileManager dependency.
struct FileView: View, Equatable {
	@ObservedObject var file: FileViewModel
	@State private var isHovering = false
	
	static func == (lhs: FileView, rhs: FileView) -> Bool {
		lhs.file.id == rhs.file.id
		&& lhs.file.isChecked == rhs.file.isChecked
		&& lhs.file.name == rhs.file.name
		&& lhs.file.loadingState == rhs.file.loadingState
		&& lhs.isHovering == rhs.isHovering
	}
	
	var body: some View {
		Button(action: {
			file.toggleIsChecked()
		}) {
			HStack(spacing: 8) {
				CheckboxView(isChecked: file.isChecked ? .checked : .unchecked) {
					file.toggleIsChecked()
				}
				.disabled(file.loadingState == .error)
				
				Image(systemName: "doc")
					.foregroundColor(.gray)
				
				Text(file.name)
					.foregroundColor(file.loadingState == .error ? .red : .primary)
					.lineLimit(1)
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 4)
			.cornerRadius(4)
			.background(
				isHovering ?
				RoundedRectangle(cornerRadius: 4)
					.stroke(Color(nsColor: .separatorColor), lineWidth: 1.5)
				: nil
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(file.loadingState == .error)
		.frame(height: 24)
		.onHover { hovering in
			isHovering = hovering
		}
		.contextMenu {
			Button(action: { file.copyContentsToPasteboard() }) {
				Label("Copy", systemImage: "doc.on.clipboard")
			}
			Button(action: { file.openInDefaultApp() }) {
				Label("Open File", systemImage: "arrow.up.right.square")
			}
			Button(action: { file.revealInFinder() }) {
				Label("Reveal in Finder", systemImage: "folder")
			}
			Button(action: { file.copyRelativePathToPasteboard() }) {
				Label("Copy Relative Path", systemImage: "link")
			}
			Button(action: { file.copyFullPathToPasteboard() }) {
				Label("Copy Full Path", systemImage: "doc.on.clipboard")
			}
		}
		.id(file.id)
	}
	
	// MARK: - Actions
	
	// Copy actions live on FileViewModel.
}
