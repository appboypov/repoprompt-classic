import SwiftUI
import UniformTypeIdentifiers

struct FileTreeView: View {
	@ObservedObject private var fileManager: RepoFileManagerViewModel
	@ObservedObject private var searchViewModel: SearchFileTreeViewModel
	@State private var showPastePathsSheet = false
	@State private var addFolderErrorMessage: String? = nil
	
	@ObservedObject private var workspaceViewModel: WorkspaceManagerViewModel
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	/// The ID of the hosting window (used when posting notifications)
	let windowID: Int
	
	/// Optional closures we can call to open or manage workspaces
	let onOpenWorkspace: (WorkspaceModel) -> Void
	let onManageWorkspaces: () -> Void
	
	/// Whether the "Filters" overlay is shown
	@State private var showFilterOverlay = false
	
	/// Whether to highlight the drop area with a dashed outline
	@State private var isDraggingOver = false
	
	// Sidebar width comes from parent; default keeps old init working.
	private var workspaceLabelMaxLength: Int {
		return 14
		/*
		// Ensure we keep at least a sensible number of characters visible when narrow.
		// Conceptually "minimum 5 chars", we cap to short values for narrow widths.
		if sidebarWidth < 380 { return 10 }
		if sidebarWidth < 520 { return 14 }
		return 20
		*/
	}
	
	init(
		windowID: Int,
		fileManager: RepoFileManagerViewModel,
		workspaceViewModel: WorkspaceManagerViewModel,
		searchViewModel: SearchFileTreeViewModel,
		onOpenWorkspace: @escaping (WorkspaceModel) -> Void,
		onManageWorkspaces: @escaping () -> Void
	) {
		self.windowID          = windowID
		self.fileManager       = fileManager
		self.workspaceViewModel = workspaceViewModel
		self.onOpenWorkspace   = onOpenWorkspace
		self.onManageWorkspaces = onManageWorkspaces
		self.searchViewModel   = searchViewModel
	}
	
	init(
		windowID: Int,
		fileManager: RepoFileManagerViewModel,
		workspaceViewModel: WorkspaceManagerViewModel,
		searchViewModel: SearchFileTreeViewModel,
		onOpenWorkspace: @escaping (WorkspaceModel) -> Void,
		onManageWorkspaces: @escaping () -> Void,
		sidebarWidth: CGFloat
	) {
		self.init(
			windowID: windowID,
			fileManager: fileManager,
			workspaceViewModel: workspaceViewModel,
			searchViewModel: searchViewModel,
			onOpenWorkspace: onOpenWorkspace,
			onManageWorkspaces: onManageWorkspaces
		)
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// Toolbar + Search
			VStack(spacing: 0) {
				toolbar
					.padding(.horizontal, 4)

				//Divider()

				// Search row with folder/more actions on the right of search box
				HStack(spacing: 8) {
					searchBox
						.padding(.leading, 8)

					folderActionsMenu

					moreActionsMenu

					Spacer()
				}
				.padding(.horizontal, 8)
				.padding(.bottom, 4)
				Divider()
					.padding(.vertical, 4)

				// Main content
				content
				// Enable dragging of folders
					.onDrop(of: [UTType.fileURL], isTargeted: $isDraggingOver, perform: handleFolderDrop(providers:))
				// Dashed outline overlay if dragging
					.overlay(draggingOutline)
			}
		}
		.alert("Unable to Add Folder", isPresented: Binding(
			get: { addFolderErrorMessage != nil },
			set: { newValue in
				if !newValue { addFolderErrorMessage = nil }
			}
		)) {
			Button("OK") {
				addFolderErrorMessage = nil
			}
		} message: {
			Text(addFolderErrorMessage ?? "Unknown error.")
		}
		// Loading overlay
		.overlay(loadingOverlay)
		// "Filters" overlay
		.sheet(isPresented: $showFilterOverlay) {
			FilterOverlayView(isVisible: $showFilterOverlay, fileManager: fileManager)
		}
		.sheet(isPresented: $showPastePathsSheet) {
			PastePathsSheet(fileManager: fileManager)
		}
	}
	
	// MARK: - Drag Handling
	
	/// Shows a dashed outline over the entire view when user drags a folder in
	private var draggingOutline: some View {
		Group {
			if isDraggingOver {
				RoundedRectangle(cornerRadius: 8)
					.stroke(style: StrokeStyle(lineWidth: 3, dash: [8]))
					.foregroundColor(.accentColor)
					.padding(8)
					.transition(.opacity)
			}
		}
	}
	
	/// Handle folder drops
	private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
		var accepted = false
		
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				accepted = true // Accept the drop immediately
				
				provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
					guard
						let data = item as? Data,
						let droppedURL = URL(dataRepresentation: data, relativeTo: nil)
					else {
						return
					}
					// Check if it's a directory
					var isDir: ObjCBool = false
					FileManager.default.fileExists(atPath: droppedURL.path, isDirectory: &isDir)
					guard isDir.boolValue else {
						print("Dropped item is not a directory: \(droppedURL.path)")
						return
					}
					
					// Create new or add to current workspace
					Task {
						await openWorkspace(from: droppedURL)
					}
				}
			}
		}
		
		return accepted
	}
	
	// MARK: - Main Content
	
	@ViewBuilder
	private var content: some View {
		let isSearchActive = !searchViewModel.searchText.isEmpty
		ZStack {
			FileTreeContainerViewWrapper(
				windowID: windowID,
				fileManager: fileManager,
				workspaceManager: workspaceViewModel,
				searchViewModel: searchViewModel
			)
			.background(Color.clear)
			
			if !isSearchActive {
				if shouldShowNoFolders {
					NoFoldersPlaceholder(
						onSelectFolder: { Task { await pickFolderAndAddOrCreate() } }
					)
				}
			}
		}
	}

	
	/*
	/// If we do have an active workspace and at least one root folder
	private var fileListView: some View {
		// MARK: - Original SwiftUI List implementation
		List {
			ForEach(fileManager.visibleRootFolders, id: \.id) { rootFolder in
				RootFolderView(
					folder: rootFolder,
					sortMethod: fileManager.currentSortMethod,
					onUnloadRootFolder: { folderToUnload in
						fileManager.requestUnloadRootFolder(path: rootFolder.fullPath)
					}
				)
			}
		}
		.listStyle(SidebarListStyle())
		.scrollContentBackground(.hidden)
		.background(Color.clear)
	}
	*/
	
	// MARK: - State Determination
	
	private var shouldShowNoFolders: Bool {
		guard let active = workspaceViewModel.activeWorkspace, !active.isSystemWorkspace else {
			return false
		}
		return fileManager.visibleRootFolders.isEmpty
	}
	
	// MARK: - Loading Overlay
	
	private var loadingOverlay: some View {
		Group {
			if fileManager.isLoading && !workspaceViewModel.isWorkspaceSwitchOverlayVisible {
				ZStack {
					Color.black.opacity(0.3)
						.edgesIgnoringSafeArea(.all)
					
					VStack(spacing: 4) {
						VStack(spacing: 8) {
							ProgressView()
								.progressViewStyle(CircularProgressViewStyle(tint: .white))
								.scaleEffect(1.5)
							Text("Loading files...")
								.foregroundColor(.white)
								.font(.headline)
						}
						
						Spacer()
						
						Button(action: {
							fileManager.cancelAllLoadingTasks()
						}) {
							Text("Cancel")
						}
						.buttonStyle(CustomButtonStyle())
					}
					.padding(16)
					.background(
						RoundedRectangle(cornerRadius: 20)
							.fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
					)
					.frame(maxWidth: .infinity, maxHeight: 96)
				}
			}
		}
	}
	
	// MARK: - Toolbar & Search
	
	private var toolbar: some View {
		HStack(alignment: .center, spacing: 8) {
			// Workspace dropdown
			workspaceDropdown
				.layoutPriority(2)
				//.fixedSize(horizontal: true, vertical: false)

			// Clear selection button
			Button(action: {
				Task {
					await fileManager.clearSelection(persistWorkspace: true)
				}
			}) {
				HStack {
					Image(systemName: "xmark.circle")
					Text("Clear")
						.font(fontPreset.font)
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
			.hoverTooltip("Clear Selection", .top)
			.layoutPriority(-1)

			// Exit workspace button (always visible, disabled when in system workspace)
			Button(action: {
				if let activeWS = workspaceViewModel.activeWorkspace, !activeWS.isSystemWorkspace {
					Task { await workspaceViewModel.saveAndExitToFallback() }
				}
			}) {
				HStack {
					Image(systemName: "rectangle.portrait.and.arrow.right")
					Text("Exit")
						.font(fontPreset.font)
						.lineLimit(1)
				}
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
			.disabled(workspaceViewModel.activeWorkspace?.isSystemWorkspace ?? true)
			.hoverTooltip("Exit Workspace", .top)
			.layoutPriority(2)
			//.fixedSize(horizontal: true, vertical: false)

			Spacer()
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.frame(height: 44)
	}

	private var folderActionsMenu: some View {
		Menu {
			Button(action: {
				Task { await pickFolderAndAddOrCreate() }
			}) {
				HStack {
					Image(systemName: "folder.badge.plus")
					Text("Add Folder")
				}
			}

			Divider()

			// Remove Folder submenu
			if !fileManager.visibleRootFolders.isEmpty {
				ForEach(fileManager.visibleRootFolders, id: \.id) { folder in
					Button(action: {
						fileManager.requestUnloadRootFolder(path: folder.fullPath)
					}) {
						HStack {
							Image(systemName: "folder.badge.minus")
							Text("Remove \(folder.name)")
						}
					}
				}

				Divider()

				Button("Remove All Folders") {
					if let ws = workspaceViewModel.activeWorkspace {
						Task {
							await workspaceViewModel.unloadAllFolders(from: ws)
						}
					}
				}
			}
		} label: {
			HStack {
				Image(systemName: "folder")
				Image(systemName: "chevron.down")
					.font(.system(size: 10))
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
		.hoverTooltip(foldersTooltip, .top)
		.layoutPriority(-1)
	}

	private var moreActionsMenu: some View {
		Menu {
			sortingSubmenu

			Divider()

			Button(action: { showPastePathsSheet = true }) {
				HStack {
					Image(systemName: "doc.on.clipboard")
					Text("Paste Paths…")
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}

			Divider()

			Button(action: { showFilterOverlay.toggle() }) {
				HStack {
					Image(systemName: "line.3.horizontal.decrease.circle")
					Text("Filters")
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}

			Divider()

			Button(action: { refreshWorkspace(soft: false) }) {
				HStack {
					Image(systemName: "arrow.clockwise")
					Text("Refresh")
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}
		} label: {
			HStack(spacing: 2) {
				Image(systemName: "ellipsis.circle")
				Image(systemName: "chevron.down")
					.font(.system(size: 10))
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
		.hoverTooltip("More actions", .top)
		.layoutPriority(-1)
	}

	private var sortingDropdown: some View {
		Menu {
			ForEach(SortMethod.fileTreeAllowed, id: \.self) { method in
				Button(action: {
					fileManager.setFileTreeSortMethod(method)
				}) {
					HStack {
						Text(method.displayName)
						Spacer()
						Image(systemName: method.icon)
						if fileManager.currentSortMethod == method {
							Image(systemName: "checkmark")
						}
					}
				}
			}
		} label: {
			HStack {
				Image(systemName: fileManager.currentSortMethod.icon)
				Text("Sort")
				Image(systemName: "chevron.up.chevron.down")
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
		.hoverTooltip("Sort files", .top)
	}
	
	private var workspaceDropdown: some View {
		WorkspacePickerMenu(
			workspaceManager: workspaceViewModel,
			includeSaveActions: true,
			onManageWorkspaces: onManageWorkspaces
		) {
			HStack(spacing: 4) {
				Text(truncatedWorkspaceLabel)
					.font(fontPreset.font)
					.lineLimit(1)
				Image(systemName: "chevron.down")
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 28))
		.hoverTooltip(workspaceTooltip, .top)
	}
	
	private var currentWorkspaceLabel: String {
		guard let ws = workspaceViewModel.activeWorkspace,
				!ws.isSystemWorkspace else { return "No Workspace" }
		return ws.name
	}
	
	private var truncatedWorkspaceLabel: String {
		let label = currentWorkspaceLabel
		let maxLength = workspaceLabelMaxLength
		guard label.count > maxLength else { return label }
		return String(label.prefix(maxLength)) + "..."
	}
	
	private var workspaceTooltip: String {
		guard let ws = workspaceViewModel.activeWorkspace,
				!ws.isSystemWorkspace else { return "Switch workspace" }
		
		return "Switch workspace • \(ws.name)"
	}
	
	private var foldersTooltip: String {
		var tooltip = "Folder actions"
		
		if let ws = workspaceViewModel.activeWorkspace, !ws.isSystemWorkspace {
			if !ws.repoPaths.isEmpty {
				tooltip += "\n\nCurrent folders:"
				let pathsToShow = ws.repoPaths.prefix(3)
				for path in pathsToShow {
					let folderName = (path as NSString).lastPathComponent
					tooltip += "\n• \(folderName)"
				}
				if ws.repoPaths.count > 3 {
					tooltip += "\n• ..."
				}
			} else {
				tooltip += "\n\nNo folders in workspace"
			}
		}
		
		return tooltip
	}
	
	private var sortingSubmenu: some View {
		Menu {
			ForEach(SortMethod.fileTreeAllowed, id: \.self) { method in
				Button(action: {
					fileManager.setFileTreeSortMethod(method)
				}) {
					HStack {
						Text(method.displayName)
						Spacer()
						Image(systemName: method.icon)
						if fileManager.currentSortMethod == method {
							Image(systemName: "checkmark")
						}
					}
				}
			}
		} label: {
			HStack {
				Image(systemName: "arrow.up.arrow.down")
				Text("Sort")
			}
		}
	}
	
	
	private var searchBox: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass")
				.foregroundColor(Color(NSColor.labelColor).opacity(0.6))
				.font(.system(size: 14))
			
			TextField("Search files", text: $searchViewModel.searchText)
				.textFieldStyle(PlainTextFieldStyle())
				.font(fontPreset.font)
				.foregroundColor(Color(NSColor.labelColor))
				.onSubmit {
					// Keep focus on search field when pressing Enter
				}
				.onKeyPress(.escape) {
					if !searchViewModel.searchText.isEmpty {
						searchViewModel.cancelSearch()
						return .handled
					}
					return .ignored
				}
			
			if !searchViewModel.searchText.isEmpty {
				Button(action: { searchViewModel.cancelSearch() }) {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
						.font(.system(size: 12))
				}
				.buttonStyle(PlainButtonStyle())
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(Color.clear)
		.cornerRadius(16)
		.overlay(
			RoundedRectangle(cornerRadius: 16)
				.stroke(Color(NSColor.systemGray).opacity(0.75), lineWidth: 0.5)
		)
	}
	
	// MARK: - Helpers
	
	/// Picks a folder and either creates a new workspace (if fallback) or adds to the current workspace.
	@MainActor
	private func pickFolderAndAddOrCreate() async {
		do {
			try await workspaceViewModel.pickFolderAndOpenWorkspace(
				title: "Add Folder",
				message: "Choose a folder to add to your workspace.",
				behavior: .addToActiveOrCreateNew
			)
		} catch {
			addFolderErrorMessage = error.localizedDescription
		}
	}
	
	/// Shared function for both drag-and-drop and the plus button flow
	@MainActor
	private func openWorkspace(from url: URL) async {
		do {
			try await workspaceViewModel.openWorkspace(fromFolderURL: url, behavior: .addToActiveOrCreateNew)
		} catch {
			addFolderErrorMessage = error.localizedDescription
		}
	}
	
	private func refreshWorkspace(soft: Bool) {
		if let ws = workspaceViewModel.activeWorkspace {
			Task {
				await workspaceViewModel.refreshWorkspace(soft: soft, for: ws)
			}
		}
	}
}

/// A concise layout with a prominent "Open Folder" button and neatly grouped content.
private struct NoWorkspacePlaceholder: View {
	@ObservedObject var workspaceViewModel: WorkspaceManagerViewModel
	let onOpenWorkspace: (WorkspaceModel) -> Void
	let onManageWorkspaces: () -> Void
	let onSelectFolder: () -> Void
	
	// Add font scaling support
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		VStack(spacing: 16) {
			// Title + short explanation
			VStack(spacing: 6) {
				Text("Workspaces")
					.font(fontPreset.headlineFont)
				Text("Open or drag a folder to create a new workspace.")
					.font(fontPreset.font)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			
			// Open Folder button
			Button(action: onSelectFolder) {
				HStack {
					Image(systemName: "folder.badge.plus")
					Text("Open Folder")
						.font(fontPreset.font)
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 4)
			}
			.buttonStyle(CustomButtonStyle())
			.hoverTooltip("Open a folder and create a new workspace", .top)
			
			// Divider between new-workspace and existing-workspaces
			Divider().padding(.vertical, 4)
			
			// Existing Workspaces
			if userWorkspaces.isEmpty {
				Text("No existing workspaces")
					.font(fontPreset.font)
					.foregroundColor(.secondary)
			} else {
				VStack(spacing: 8) {
					Text("Recent workspaces")
						.font(fontPreset.subheadlineFont)
						.foregroundColor(.secondary)
					
					ForEach(userWorkspaces.prefix(5)) { ws in
						Button(action: { onOpenWorkspace(ws) }) {
							Text(ws.name)
								.font(fontPreset.font)
						}
						.buttonStyle(LinkButtonStyle())
					}
				}
				
				// Manage Workspaces button below the list
				if !userWorkspaces.isEmpty {
					Divider()
						.padding(.vertical, 6)
					
					Button(action: onManageWorkspaces) {
						HStack(spacing: 4) {
							Image(systemName: "slider.horizontal.3")
								.font(fontPreset.captionFont)
							Text("Manage Workspaces…")
								.font(fontPreset.subheadlineFont)
						}
						.foregroundColor(.secondary)
					}
					.buttonStyle(PlainButtonStyle())
					.hoverEffect()
					.hoverTooltip("Edit, rename, or delete workspaces", .top)
				}
			}
		}
		// Keep everything nicely centered with a fixed width
		.frame(maxWidth: 300, maxHeight: .infinity)
		.padding(.top, 16)
		.padding(.horizontal, 16)
	}
	
	private var userWorkspaces: [WorkspaceModel] {
		workspaceViewModel.workspacesForMenu()
	}
}

private struct NoFoldersPlaceholder: View {
	let onSelectFolder: () -> Void
	
	// Add font scaling support
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		VStack(alignment: .center, spacing: 12) {
			Text("No Folders in this Workspace")
				.font(fontPreset.headlineFont)
			Text("Select a folder to add to this workspace.")
				.font(fontPreset.font)
				.foregroundColor(.secondary)
			
			Button {
				onSelectFolder()
			} label: {
				HStack {
					Image(systemName: "folder.badge.plus")
					Text("Add Folder")
						.font(fontPreset.font)
				}
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 8, horizontalPadding: 16, height: 32))
			.hoverTooltip("Add a folder to this workspace", .top)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.clear)
	}
}

