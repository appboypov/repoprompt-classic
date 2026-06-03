import SwiftUI

struct DiffHeaderFileTags: View {
	let files: [FileViewModel]
	let onRemove: (FileViewModel) -> Void
	
	var body: some View {
		HStack(spacing: 8) {
			Text("Files:")
				.font(.subheadline)
				.foregroundColor(.secondary)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.frame(width: 50)
				.overlay(
					RoundedRectangle(cornerRadius: 4)
						.stroke(Color.secondary.opacity(0.2), lineWidth: 1)
				)
			
			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(spacing: 8) {
					ForEach(files.indices, id: \.self) { index in
						let file = files[index]
						DiffFileTag(file: file, onRemove: onRemove, rowIndex: index)
					}
				}
				.padding(.horizontal, 2)
				.padding(.vertical, 4)
			}
		}
		.frame(maxHeight: .infinity)
	}
}

private struct DiffFileTag: View {
	let file: FileViewModel
	let onRemove: (FileViewModel) -> Void
	let rowIndex: Int
	
	var body: some View {
		HStack(spacing: 8) {
			Text(file.name)
				.font(.system(.subheadline, design: .rounded).weight(.semibold))
				.foregroundColor(.primary)
				.lineLimit(1)
				.truncationMode(.tail)
			
			Text(file.relativePath)
				.font(.system(.caption, design: .monospaced))
				.foregroundColor(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
			
			Button {
				onRemove(file)
			} label: {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 11))
					.foregroundColor(.secondary)
			}
			.buttonStyle(.plain)
			.hoverTooltip("Remove file from diff")
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(
			rowIndex % 2 == 0
				? Color(NSColor.controlBackgroundColor).opacity(0.24)
				: Color(NSColor.controlBackgroundColor).opacity(0.12)
		)
		.cornerRadius(6)
	}
}
