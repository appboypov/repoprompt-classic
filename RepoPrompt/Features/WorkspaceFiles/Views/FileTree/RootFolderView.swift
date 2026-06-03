import SwiftUI

struct RootFolderView: View, Equatable {
	@ObservedObject var folder: FolderViewModel
	let sortMethod: SortMethod
	var onUnloadRootFolder: ((FolderViewModel) -> Void)?
	
	static func == (lhs: RootFolderView, rhs: RootFolderView) -> Bool {
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
			RootFolderLabel(folder: folder, onUnloadRootFolder: onUnloadRootFolder)
		}
	}
}

struct RootFolderLabel: View {
	@ObservedObject var folder: FolderViewModel
	var onUnloadRootFolder: ((FolderViewModel) -> Void)?
	
	@State private var isHovering = false
	@State private var isHoveringCollapseButton = false
	@State private var isHoveringExpandButton = false
	@State private var isHoveringXButton = false
	
	var body: some View {
		HStack(spacing: 0) {
			// Folder Checkbox
			CheckboxView(isChecked: folder.checkboxState) {
				folder.toggleCheckedRecursive()
			}
			.padding(.trailing, 4)
			.onTapGesture {
				folder.toggleCheckedRecursive()
			}
			
			// Folder Name + Actions
			HStack {
				Image(systemName: "folder")
					.foregroundColor(.gray)
				
				Text(folder.name)
				
				Spacer(minLength: 0)
				
				// Collapse All
				Button(action: {
					folder.collapseRecursively()
				}) {
					Image(systemName: "rectangle.compress.vertical")
						.foregroundColor(isHoveringCollapseButton ? .accentColor : .secondary)
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip("Collapse All Children")
				//.keyboardShortcut("c", modifiers: [.command, .option])
				.onHover { hovering in
					isHoveringCollapseButton = hovering
				}
				
				/*
				// Expand All
				Button(action: {
					folder.expandRecursively()
				}) {
					Image(systemName: "rectangle.expand.vertical")
						.foregroundColor(isHoveringExpandButton ? .accentColor : .secondary)
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip("Expand All Children")
				//.keyboardShortcut("e", modifiers: [.command, .option])
				.onHover { hovering in
					isHoveringExpandButton = hovering
				}
				*/
				
				// Unload Root
				Button(action: {
					onUnloadRootFolder?(folder)
				}) {
					Image(systemName: "xmark.circle")
						.foregroundColor(isHoveringXButton ? .red : .secondary)
				}
				.buttonStyle(PlainButtonStyle())
				.onHover { hovering in
					isHoveringXButton = hovering
				}
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
