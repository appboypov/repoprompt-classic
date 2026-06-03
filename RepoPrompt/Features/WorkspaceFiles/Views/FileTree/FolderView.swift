import SwiftUI

/// A SwiftUI view displaying a folder (and its children) in the file tree.
struct FolderView: View, Equatable {
	@ObservedObject var folder: FolderViewModel
	
	let sortMethod: SortMethod
	
	static func == (lhs: FolderView, rhs: FolderView) -> Bool {
		lhs.folder.id == rhs.folder.id &&
		lhs.folder.isExpanded == rhs.folder.isExpanded &&
		lhs.folder.checkboxState == rhs.folder.checkboxState &&
		lhs.sortMethod == rhs.sortMethod
	}
	
	var body: some View {
		DisclosureGroup(isExpanded: $folder.isExpanded) {
			ForEach(folder.children, id: \.id) { item in
				switch item {
				case .folder(let subFolder):
					FolderView(
						folder: subFolder,
						sortMethod: sortMethod
					)
				case .file(let file):
					FileView(file: file)
				}
			}
		} label: {
			NonRootFolderLabel(folder: folder)
		}
	}
}

struct NonRootFolderLabel: View {
	@ObservedObject var folder: FolderViewModel
	@State private var isHovering = false
	
	var body: some View {
		HStack(spacing: 0) {
			CheckboxView(isChecked: folder.checkboxState) {
				folder.toggleCheckedRecursive()
			}
			.padding(.trailing, 4)
			.onTapGesture {
				folder.toggleCheckedRecursive()
			}
			
			HStack {
				Image(systemName: "folder.fill")
					.foregroundColor(.gray)
				
				Text(folder.name)
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 4)
			.background(Color.clear)
			.cornerRadius(4)
			.background(
				isHovering ?
				RoundedRectangle(cornerRadius: 4)
					.stroke(Color(nsColor: .separatorColor), lineWidth: 1.5)
				: nil
			)
			.contentShape(Rectangle())
			.onTapGesture {
				folder.isExpanded.toggle()
			}
		}
		.frame(height: 24)
		.contentShape(Rectangle())
		.onHover { hovering in
			isHovering = hovering
		}
	}
}