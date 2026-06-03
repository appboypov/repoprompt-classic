import SwiftUI
import AppKit

struct SearchFileTreeView: View {
	@ObservedObject var searchViewModel: SearchFileTreeViewModel
	
	var body: some View {
		ZStack {
			// Native AppKit outline wrapped in SwiftUI
			SearchFileTreeViewWrapper(searchViewModel: searchViewModel)
				.background(Color.clear)
			
			if searchViewModel.isSearching && searchViewModel.rootFolders.isEmpty {
				VStack {
					ProgressView()
						.scaleEffect(1.2)
						.padding(.bottom, 8)
					
					Text("Searching...")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if searchViewModel.noResultsFound && !searchViewModel.hasSearchResults {
				Text("No results found")
					.font(.system(size: 16, weight: .medium))
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
	}
}

struct SearchFolderView: View {
	@ObservedObject var folder: SearchFolderViewModel
	@ObservedObject var searchViewModel: SearchFileTreeViewModel
	@State private var isLabelHovering = false
	
	var body: some View {
		DisclosureGroup(isExpanded: $folder.isExpanded) {
			ForEach(folder.children, id: \.id) { child in
				switch child {
				case .folder(let subFolder):
					SearchFolderView(folder: subFolder, searchViewModel: searchViewModel)
				case .file(let file):
					SearchFileView(file: file, searchViewModel: searchViewModel)
				}
			}
		} label: {
			FolderLabel(folder: folder, searchViewModel: searchViewModel, isHovering: $isLabelHovering)
		}
	}
}

struct FolderLabel: View {
	@ObservedObject var folder: SearchFolderViewModel
	@ObservedObject var searchViewModel: SearchFileTreeViewModel
	@Binding var isHovering: Bool
	
	var body: some View {
		HStack(spacing: 0) {
			// Separate tap target: Checkbox
			CheckboxView(isChecked: folder.checkboxState) {
				searchViewModel.toggleFolderSelection(folder)
			}
			.padding(.trailing, 4)
			.onTapGesture {
				searchViewModel.toggleFolderSelection(folder)
			}
			
			// The folder label + whitespace
			HStack {
				Image(systemName: "folder.fill")
					.foregroundColor(.gray)
				HighlightedText(text: folderDisplayName, highlightText: searchViewModel.searchText)
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 4)
			.background(Color.clear)
			.cornerRadius(4)
			.overlay(
				RoundedRectangle(cornerRadius: 4)
					.stroke(Color(nsColor: .separatorColor), lineWidth: 1.5)
					.opacity(isHovering ? 1 : 0)
			)
			// Make the label's whitespace clickable
			.contentShape(Rectangle())
			.onTapGesture {
				folder.isExpanded.toggle()
			}
		}
		.frame(height: 24) // Match FileView height
		.contentShape(Rectangle())
		.onHover { hovering in
			isHovering = hovering
		}
	}
	
	private var folderDisplayName: String {
		let components = folder.relativePath.split(separator: "/")
		return String(components.last ?? "")
	}
}

struct SearchFileView: View {
	@ObservedObject var file: SearchFileViewModel
	@ObservedObject var searchViewModel: SearchFileTreeViewModel
	@State private var isHovering = false
	
	var body: some View {
		HStack(spacing: 0) {
			Button(action: {
				toggleFile()
			}) {
				HStack {
					CheckboxView(isChecked: file.isChecked ? .checked : .unchecked) {
						toggleFile()
					}
					Image(systemName: "doc")
						.foregroundColor(.gray)
					HighlightedText(text: file.name, highlightText: searchViewModel.searchText)
						.foregroundColor(.primary)
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 4)
				.background(Color.clear)
				.cornerRadius(4)
				.overlay(
					RoundedRectangle(cornerRadius: 4)
						.stroke(Color(nsColor: .separatorColor), lineWidth: 1.5)
						.opacity(isHovering ? 1 : 0)
				)
			}
			.buttonStyle(PlainButtonStyle())
			
			Spacer(minLength: 0)
		}
		.frame(height: 24)
		.contentShape(Rectangle())
		.onHover { hovering in
			handleHover(hovering)
		}
		.contextMenu {
			Button(action: {
				file.originalFile?.copyContentsToPasteboard()
			}) {
				Label("Copy", systemImage: "doc.on.clipboard")
			}
			
			Button(action: {
				file.originalFile?.openInDefaultApp()
			}) {
				Label("Open File", systemImage: "arrow.up.right.square")
			}
			
			Button(action: {
				file.originalFile?.revealInFinder()
			}) {
				Label("Reveal in Finder", systemImage: "folder")
			}
		}
	}
	
	@MainActor
	private func toggleFile() {
		if let fileManager = searchViewModel.fileManager,
		   let original = file.originalFile {
			fileManager.toggleFile(original)
		}
	}
	
	private func handleHover(_ hovering: Bool) {
		isHovering = hovering
	}
}

struct HighlightedText: View {
	let text: String
	let highlightText: String
	
	var body: some View {
		if highlightText.isEmpty {
			Text(text)
		} else {
			highlightedText
		}
	}
	
	private var highlightedText: some View {
		return Text(text)
			.background(
				GeometryReader { geometry in
					ZStack(alignment: .leading) {
						ForEach(getHighlightRanges(), id: \.self) { range in
							let start = range.lowerBound.utf16Offset(in: text)
							let end = range.upperBound.utf16Offset(in: text)
							let width = getWidthForRange(start: start, end: end, in: geometry)
							Rectangle()
								.fill(Color.yellow.opacity(0.5))
								.frame(width: width)
								.offset(x: getOffsetForRange(start: start, in: geometry))
						}
					}
				}
			)
	}
	
	private func getHighlightRanges() -> [Range<String.Index>] {
		let lowercasedText = text.lowercased()
		let lowercasedHighlight = highlightText.lowercased()
		var ranges: [Range<String.Index>] = []
		var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
		
		while let range = lowercasedText.range(of: lowercasedHighlight, options: [], range: searchRange) {
			ranges.append(range)
			searchRange = range.upperBound..<lowercasedText.endIndex
		}
		
		return ranges
	}
	
	private func getWidthForRange(start: Int, end: Int, in geometry: GeometryProxy) -> CGFloat {
		let totalCount = text.count
		guard totalCount > 0 else { return 0 }
		
		let startFraction = CGFloat(start) / CGFloat(totalCount)
		let endFraction   = CGFloat(end)   / CGFloat(totalCount)
		
		let startX = geometry.size.width * startFraction
		let endX   = geometry.size.width * endFraction
		
		return endX - startX
	}
	
	private func getOffsetForRange(start: Int, in geometry: GeometryProxy) -> CGFloat {
		let totalCount = text.count
		guard totalCount > 0 else { return 0 }
		
		let fraction = CGFloat(start) / CGFloat(totalCount)
		return geometry.size.width * fraction
	}
}
