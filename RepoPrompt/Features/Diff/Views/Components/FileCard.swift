//
//  FileCard.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-14.
//

import SwiftUI

struct FileCard: View {
	let file: ParsedFile
	@ObservedObject var viewModel: DiffViewModel
	@State private var isExpanded = true
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				if !file.canBeLoaded && file.action != .create {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.yellow)
				} else {
					CheckboxView(isChecked: viewModel.fileSelectionState(for: file.id)) {
						viewModel.toggleAllChangesForFile(fileId: file.id)
					}
				}
				Text(file.fileName)
					.font(.headline)
				Spacer()
				Text(file.action.rawValue.capitalized)
					.font(.subheadline)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(actionColor)
					.foregroundColor(.white)
					.cornerRadius(6)
				Text("\(file.changes.count) changes")
					.font(.subheadline)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(Color(NSColor.controlBackgroundColor))
					.cornerRadius(6)
				Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
			}
			.contentShape(Rectangle())
			.onTapGesture {
				withAnimation {
					isExpanded.toggle()
				}
			}
			
			if isExpanded && file.action != .delete {
				LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
					ForEach(file.changes) { change in
						ChangeItem(change: change, viewModel: viewModel, fileId: file.id, canBeLoaded: file.canBeLoaded)
					}
				}
			}
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor).opacity(0.6))
		.cornerRadius(8)
	}
	
	var actionColor: Color {
		switch file.action {
		case .create:
			return .green
		case .modify, .delegateEdit:
			return .blue
		case .rewrite:
			return .purple
		case .delete:
			return .red
		}
	}
}
