//
//  SelectedFileView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-04.
//
import SwiftUI
import Foundation
import Combine

// Extension for conditional view modifiers
extension View {
	@ViewBuilder
	func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
		if condition {
			transform(self)
		} else {
			self
		}
	}
}


// =========================================
// Selected Files Content View
// =========================================
	struct SelectedFilesContentView: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var promptManager: PromptViewModel
	@Binding var selectedFile: FileViewModel?
	let selectFileForPreview: (FileViewModel?) -> Void
	let windowID: Int
	@ObservedObject private var panelVM: SelectedFilesPanelViewModel
	@State private var isHoveringExpandButton = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	enum ContentViewMode: String, CaseIterable {
		case fullFiles = "Full Files"
		case codemaps = "APIs Only"
	}
	
	init(
		fileManager: RepoFileManagerViewModel,
		promptManager: PromptViewModel,
		selectedFile: Binding<FileViewModel?>,
		selectFileForPreview: @escaping (FileViewModel?) -> Void,
		windowID: Int,
		panelViewModel: SelectedFilesPanelViewModel
	) {
		self._fileManager = ObservedObject(initialValue: fileManager)
		self._promptManager = ObservedObject(initialValue: promptManager)
		self._selectedFile = selectedFile
		self.selectFileForPreview = selectFileForPreview
		self.windowID = windowID
		self._panelVM = ObservedObject(wrappedValue: panelViewModel)
	}

	
	// MARK: - Helper Methods

	// MARK: - UI Scaling Properties

	/// Current font scale factor for UI elements
	private var scaleFactor: CGFloat {
		fontPreset.scaleFactor
	}
	
	/// Scaled button height
	private var buttonHeight: CGFloat {
		return 22 * scaleFactor
	}
	
	/// Standard horizontal padding scaled with font size
	private var horizontalPadding: CGFloat {
		return 8 * scaleFactor
	}
	
	/// Small horizontal padding scaled with font size
	private var smallPadding: CGFloat {
		return 4 * scaleFactor
	}
	
	/// Icon size scaled with font size
	private var iconSize: CGFloat {
		return 22 * scaleFactor
	}
	
	/// Divider height scaled with font size
	private var dividerHeight: CGFloat {
		return 16 * scaleFactor
	}
	
	private var snapshot: SelectedFilesSnapshot { panelVM.snapshot }
	
	private var fileDisplayMode: FileDisplayMode { panelVM.displayMode }
	
	private var contentViewMode: ContentViewMode { snapshot.contentMode }
	
	var body: some View {
		VStack(spacing: 8) {
			// Header with buttons
			HStack(spacing: 6) {
				presetsMenu
				sortButton
				optionsButton
				
				Spacer()
				fileContentToggle
			}
			
			// Content section
			if snapshot.isEmpty {
				emptyStateView
			} else {
				fileContentView()
			}
		}
	}
	
	// MARK: - UI Components
	
	private var sortButton: some View {
		Menu {
			ForEach(SortMethod.selectedFilesAllowed, id: \.self) { method in
				Button {
					promptManager.selectedFilesSortMethod = method
				} label: {
					HStack {
						Text(method.displayName)
							.font(fontPreset.font)
						Spacer()
						Image(systemName: method.icon)
						if promptManager.selectedFilesSortMethod == method {
							Image(systemName: "checkmark")
						}
					}
				}
			}
		} label: {
			HStack(spacing: smallPadding) {
				Image(systemName: promptManager.selectedFilesSortMethod.icon)
				Text("Sort")
					.font(fontPreset.font)
				Image(systemName: "chevron.up.chevron.down")
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: horizontalPadding, height: buttonHeight))
		.if(snapshot.totalFileCount == 0) { view in
			view.hoverTooltip("Choose sort order for\nselected files and folders", .bottom)
		}
	}

	private var presetsMenu: some View {
		PresetsMenuView(windowID: windowID)
	}
	
	private var optionsButton: some View {
		Menu {
			Section {
				Picker(selection: Binding(
					get: { panelVM.displayMode },
					set: { newMode in
						panelVM.setDisplayMode(newMode)
					}
				), label: Label("View Mode", systemImage: "eye")) {
					Label("Folders", systemImage: "folder").tag(FileDisplayMode.folders)
					Label("Files", systemImage: "doc").tag(FileDisplayMode.files)
				}
			}
			if fileDisplayMode == .folders {
				Section {
					Button {
						if anyFoldersExpanded {
							for group in snapshot.folderGroups where !group.files.isEmpty {
								promptManager.collapsedFolders.insert(group.path)
							}
						} else {
							promptManager.collapsedFolders.removeAll()
						}
					} label: {
						Label(anyFoldersExpanded ? "Collapse All Folders" : "Expand All Folders", systemImage: anyFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
					}
				}
			}
			Section {
				if !fileManager.autoCodemapFiles.isEmpty {
					Button {
						fileManager.clearAutoCodemapFiles()
					} label: {
						Label("Clear Selected Codemaps", systemImage: "function")
					}
				}
				Button {
					Task { await fileManager.clearSelection(persistWorkspace: true) }
				} label: {
					Label("Clear File Selection", systemImage: "xmark.circle")
				}
			}
		} label: {
			Image(systemName: "gearshape")
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: smallPadding, height: buttonHeight))
		.if(snapshot.totalFileCount == 0) { view in
			view.hoverTooltip("More file selection options", .bottom)
		}
	}
	
	private struct PresetsMenuView: View {
		@EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
		@ObservedObject private var fontScale = FontScaleManager.shared
		private var fontPreset: FontScalePreset { fontScale.preset }
		private var buttonHeight: CGFloat { 22 * fontPreset.scaleFactor }
		let windowID: Int
		
		@State private var refreshTrigger = UUID()
		
		private var menuTitle: String {
			guard let ws = workspaceManager.activeWorkspace else { return "Presets" }
			var title = ws.activePresetID
				.flatMap { pid in ws.presets.first(where: { $0.id == pid })?.name } ?? "Presets"
			if workspaceManager.activePresetIsDirty { title += " *" }
			return title
		}
		
		var body: some View {
			Menu {
				content
			} label: {
				HStack(spacing: 4) {
					Text(menuTitle)
						.font(fontPreset.font)
						.lineLimit(1)
						.truncationMode(.tail)
					Image(systemName: "chevron.down")
						.font(.system(size: 10))
				}
			}
			.id(refreshTrigger)
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 12, height: buttonHeight))
			.hoverTooltip("Switch between file presets (⌘⌥1-9)", .bottom)
			.onReceive(NotificationCenter.default.publisher(for: .workspaceListDidChange).receive(on: RunLoop.main)) { _ in
				refreshTrigger = UUID()
			}
		}
		
		@ViewBuilder
		private var content: some View {
			if let ws = workspaceManager.activeWorkspace {
				Text("Quickly switch between sets of files.\nUse ⌘⌥1-9 to switch.")
					.font(.caption)
					.foregroundColor(Color(NSColor.labelColor))
				Divider()
				
				if ws.presets.isEmpty {
					Button("(No Presets)") {}.disabled(true)
				} else {
					ForEach(ws.presets.indices, id: \.self) { idx in
						let preset = ws.presets[idx]
						Button("[\(idx+1)] \(preset.name)") {
							Task { await workspaceManager.applyPreset(preset.id) }
						}
						.disabled(preset.id == ws.activePresetID && !workspaceManager.activePresetIsDirty)
					}
				}
				
				Divider()
				Button("Save Current Preset (⌘⌥S)") {
					if workspaceManager.activeWorkspace?.presets.isEmpty ?? true {
						NotificationCenter.default.post(
							name: .showCreatePresetSheet,
							object: nil,
							userInfo: ["windowID": windowID])
					} else {
						Task { await workspaceManager.saveCurrentPreset() }
					}
				}
				
				Button("Create New Preset (⌘⌥P)") {
					Task {
						NotificationCenter.default.post(
							name: .showCreatePresetSheet,
							object: nil,
							userInfo: ["windowID": windowID])
					}
				}
				
				Divider()
				Button("Manage Presets…") {
					NotificationCenter.default.post(
						name: .showManagePresetsTab,
						object: nil,
						userInfo: ["windowID": windowID])
				}
			} else {
				Button("(No Active Workspace)") {}.disabled(true)
			}
		}
	}
	
	private var clearButton: some View {
		Button {
			Task{
				await fileManager.clearSelection(persistWorkspace: true)
			}
		} label: {
			HStack(spacing: smallPadding) {
				Image(systemName: "xmark.circle")
				Text("Clear")
					.font(fontPreset.font)
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: horizontalPadding, height: buttonHeight))
		.if(snapshot.totalFileCount == 0) { view in
			view.hoverTooltip("Clear all selected files", .bottom)
		}
	}
	
	private var expandCollapseButton: some View {
		Button {
			if anyFoldersExpanded {
				for group in snapshot.folderGroups where !group.files.isEmpty {
					promptManager.collapsedFolders.insert(group.path)
				}
			} else {
				promptManager.collapsedFolders.removeAll()
			}
		} label: {
			Image(systemName: anyFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
				.foregroundColor(isHoveringExpandButton ? .accentColor : .secondary)
				.frame(width: iconSize, height: iconSize)
				.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { isHoveringExpandButton = $0 }

		.if(snapshot.totalFileCount == 0) { view in
			view.hoverTooltip(anyFoldersExpanded ? "Collapse all folders" : "Expand all folders", .bottom)
		}
	}
	
	private var anyFoldersExpanded: Bool {
		snapshot.folderGroups.contains { $0.isExpanded && !$0.files.isEmpty }
	}
	
	private var displayToggleButton: some View {
	Picker("View Mode", selection: Binding(
		get: { panelVM.displayMode },
		set: { newMode in
			panelVM.setDisplayMode(newMode)
		}
	)) {
        Image(systemName: "folder").tag(FileDisplayMode.folders)
        Image(systemName: "doc").tag(FileDisplayMode.files)
    }
		.pickerStyle(.segmented)
		.labelsHidden()
		.frame(width: 70 * scaleFactor)
		.if(snapshot.totalFileCount == 0) { view in
			view.hoverTooltip("Toggle between folder\nand file view", .bottom)
		}
	}
	
	private var fileStatsView: some View {
		HStack(spacing: 0) {
			let totalCount = snapshot.totalFileCount
			let codemapCount = snapshot.apiCodemapCount
			let tokenLabel = snapshot.displayTokenCount

			Text("\(totalCount) \(totalCount == 1 ? "file" : "files")")
				.font(fontPreset.captionFont)
				.lineLimit(1)
				.truncationMode(.tail)
				.padding(.horizontal, horizontalPadding)
				.padding(.vertical, smallPadding)

			if codemapCount > 0 {
				Text("(\(codemapCount) API)")
					.font(fontPreset.captionFont)
					.foregroundColor(.blue)
					.lineLimit(1)
					.truncationMode(.tail)
					.padding(.horizontal, smallPadding)
					.padding(.vertical, smallPadding)
			}
			
			Divider().frame(height: dividerHeight).padding(.horizontal, smallPadding)

			Text("~\(tokenLabel) Tokens")
				.font(fontPreset.captionFont)
				.lineLimit(1)
				.truncationMode(.tail)
				.padding(.horizontal, horizontalPadding)
				.padding(.vertical, smallPadding)
		}
		.background(Color.secondary.opacity(0.1))
		.cornerRadius(16)
	}
	
	private var emptyStateView: some View {
		Text("No files selected. Use the side bar to find files to include in your prompt.")
			.foregroundColor(.secondary)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
	}
	
	private var fileContentToggle: some View {
		// In selected codemap mode, show a simple display instead of toggle
		if snapshot.codeMapUsage == .selected {
			return AnyView(selectedCodemapDisplay)
		} else {
			return AnyView(normalToggleDisplay)
		}
	}

	// Display for selected codemap mode
	private var selectedCodemapDisplay: some View {
		HStack(spacing: 4) {
		let count = snapshot.fullFilesCount
		let tokenCount = snapshot.selectedModeTokenCount

			Text("Selected")
				.font(fontPreset.captionFont.weight(.semibold))
				.foregroundColor(.primary)

			Text("\(count)")
				.font(fontPreset.captionFont)
				.foregroundColor(.primary.opacity(0.7))

			Text("•")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary.opacity(0.5))

			Text("~\(String(format: "%.2fk", Double(tokenCount) / 1000.0))")
				.font(fontPreset.captionFont)
				.foregroundColor(.primary.opacity(0.7))
		}
		.padding(.horizontal, horizontalPadding)
		.padding(.vertical, smallPadding)
		.padding(2)
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color.accentColor.opacity(0.2))
		)
		.hoverTooltip("Selected files mode: Files with APIs shown as codemaps,\nothers shown in full")
	}

	// Normal toggle display for non-selected modes
	private var normalToggleDisplay: some View {
		HStack(spacing: 0) {
			ForEach(ContentViewMode.allCases, id: \.self) { mode in
				let isActive = contentViewMode == mode
				let count = mode == .fullFiles ? snapshot.fullFilesCount : snapshot.codemapOnlyCount
				let tokenCount = mode == .fullFiles ? snapshot.fullFilesTokenCount : snapshot.codemapTokenCount
				let tokenString = String(format: "%.2fk", Double(tokenCount) / 1000.0)
				
				Button(action: {
					withAnimation(.easeInOut(duration: 0.2)) {
						panelVM.setContentMode(mode)
					}
				}) {
					HStack(spacing: 4) {
						Text(mode == .fullFiles ? "Full" : "API")
							.font(fontPreset.captionFont.weight(isActive ? .semibold : .regular))
							.foregroundColor(isActive ? .primary : .secondary)
							.lineLimit(1)
							.minimumScaleFactor(0.8)

						Text("\(count)")
							.font(fontPreset.captionFont)
							.foregroundColor(isActive ? .primary.opacity(0.7) : .secondary.opacity(0.7))
							.lineLimit(1)
							.minimumScaleFactor(0.8)

						Text("•")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary.opacity(0.5))
							.lineLimit(1)

						Text("~\(tokenString)")
							.font(fontPreset.captionFont)
							.foregroundColor(isActive ? .primary.opacity(0.7) : .secondary.opacity(0.7))
							.lineLimit(1)
							.minimumScaleFactor(0.8)
					}
					.padding(.horizontal, horizontalPadding)
					.padding(.vertical, smallPadding)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
					)
					.contentShape(Rectangle())
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip(mode == .fullFiles ? "Show files included with full content" : "Show files included as API codemaps\n(function/class signatures only)")
			}
		}
		.fixedSize(horizontal: false, vertical: true)
		.padding(2)
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color.secondary.opacity(0.15))
		)
	}
	
	// MARK: - Content Views
	
	private func fileContentView() -> some View {
		ScrollView(.vertical, showsIndicators: true) {
			LazyVStack(spacing: 8) {
				if fileDisplayMode == .folders {
					ForEach(snapshot.folderGroups) { group in
						if group.files.isEmpty { EmptyView() } else {
							FolderItemView(
								props: group,
								showTokenCount: snapshot.codeMapUsage == .selected || contentViewMode == .fullFiles,
								onSetExpanded: { isExpanded in panelVM.setFolderExpansion(path: group.path, isExpanded: isExpanded) },
								onRemoveAll: {
									for file in group.files {
										panelVM.removeFile(fullPath: file.fullPath)
										if selectedFile?.id == file.id {
											selectedFile = nil
											selectFileForPreview(nil)
										}
									}
								},
								fileBuilder: { buildFileRowView(for: $0) }
							)
						}
					}
				} else {
					let columns: [GridItem] = [GridItem(.adaptive(minimum: 280), spacing: 8)]
					LazyVGrid(columns: columns, spacing: 8) {
						ForEach(snapshot.flatFiles) { row in
							buildFileRowView(for: row)
						}
					}
				}
			}
			.padding(.horizontal, 0)
			.padding(.vertical, 4)
		}
	}

	private func buildFileRowView(for props: FileRowProps) -> FileRowView {
		FileRowView(
			props: props,
			codeMapUsage: snapshot.codeMapUsage,
			preparePreview: {
				guard let file = panelVM.resolveFileVM(
					fullPath: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				) else { return nil }
				let slices = panelVM.selectionSlices(
					for: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				)
				selectedFile = file
				selectFileForPreview(file)
				return FilePreviewContext(file: file, slices: slices)
			},
			onCopy: { panelVM.copyContents(fullPath: props.fullPath) },
			onCopyRelativePath: {
				panelVM.copyRelativePath(
					fullPath: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				)
			},
			onCopyAbsolutePath: { panelVM.copyAbsolutePath(fullPath: props.fullPath) },
			onOpenFile: {
				panelVM.openFile(
					fullPath: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				)
			},
			onRevealInFinder: {
				panelVM.revealInFinder(
					fullPath: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				)
			},
			onSetCodemap: {
				if props.canCodemap {
					panelVM.setCodemap(fullPath: props.fullPath)
				}
			},
			onSetFullContent: {
				panelVM.setFullContent(fullPath: props.fullPath)
			},
			onClearSlices: { panelVM.clearSlices(fullPath: props.fullPath) },
			onRemove: {
				panelVM.removeFile(fullPath: props.fullPath)
				if selectedFile?.id == props.id {
					selectedFile = nil
					selectFileForPreview(nil)
				}
			},
			resolveFile: {
				panelVM.resolveFileVM(
					fullPath: props.fullPath,
					uniqueRelativePath: props.uniqueRelativePath,
					relativePath: props.relativePath
				)
			}
		)
	}
	
	// MARK: - Helper Methods
	

}

// =========================================
// Supporting Views
// =========================================
struct FolderItemView: View {
	let props: FolderGroupProps
	let showTokenCount: Bool
	let onSetExpanded: (Bool) -> Void
	let onRemoveAll: () -> Void
	let fileBuilder: (FileRowProps) -> FileRowView

	@State private var isHoveringFolderIcon = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private var scaleFactor: CGFloat { fontPreset.scaleFactor }
	
	var body: some View {
		let expandedBinding = Binding<Bool>(
			get: { props.isExpanded },
			set: { newValue in
				guard newValue != props.isExpanded else { return }
				withAnimation { onSetExpanded(newValue) }
			}
		)
		
		DisclosureGroup(isExpanded: expandedBinding) {
			let columns: [GridItem] = [GridItem(.adaptive(minimum: 280), spacing: 8)]
			LazyVGrid(columns: columns, spacing: 8) {
				ForEach(props.files) { file in
					fileBuilder(file)
				}
			}
			.padding(.top, 4 * scaleFactor)
		} label: {
			HStack(spacing: 8 * scaleFactor) {
				ZStack {
					Image(systemName: "folder.fill")
						.opacity(isHoveringFolderIcon ? 0 : 1)
					Image(systemName: "xmark.circle.fill")
						.opacity(isHoveringFolderIcon ? 1 : 0)
				}
				.foregroundColor(.blue)
				.frame(width: 20 * scaleFactor, height: 20 * scaleFactor)
				.onHover { isHoveringFolderIcon = $0 }
				.onTapGesture {
					if isHoveringFolderIcon {
						onRemoveAll()
					} else {
						withAnimation { onSetExpanded(!props.isExpanded) }
					}
				}
				
				HStack(spacing: 4 * scaleFactor) {
					Text(props.path.isEmpty ? "(root)" : props.path)
						.font(fontPreset.headlineFont)
						.foregroundColor(.primary)
					Spacer()
					if showTokenCount, let tokenDisplay = props.tokenDisplayString {
						Text(tokenDisplay)
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
							.padding(.vertical, 4 * scaleFactor)
							.padding(.horizontal, 8 * scaleFactor)
							.background(Color.secondary.opacity(0.1))
							.cornerRadius(8)
					}
				}
				.contentShape(Rectangle())
				.onTapGesture {
					withAnimation { onSetExpanded(!props.isExpanded) }
				}
			}
			.padding(.horizontal, 6)
			.padding(.vertical, 4)
			.background(Color.blue.opacity(0.1))
			.cornerRadius(4)
		}
		.disclosureGroupStyle(NoArrowDisclosureGroupStyle())
		.frame(maxWidth: .infinity, alignment: .leading)
		//.hoverTooltip("Click to expand/collapse folder.\nClick the folder icon to remove\nall files from this folder.")
	}
}


struct FilePreviewContext {
	let file: FileViewModel
	let slices: [LineRange]
}

struct FileRowView: View {
	let props: FileRowProps
	let codeMapUsage: CodeMapUsage
	let preparePreview: () -> FilePreviewContext?
	let onCopy: () -> Void
	let onCopyRelativePath: () -> Void
	let onCopyAbsolutePath: () -> Void
	let onOpenFile: () -> Void
	let onRevealInFinder: () -> Void
	let onSetCodemap: () -> Void
	let onSetFullContent: () -> Void
	let onClearSlices: () -> Void
	let onRemove: () -> Void
	/// Resolver to obtain the FileViewModel for this row (used to subscribe to published counts)
	let resolveFile: () -> FileViewModel?

	@State private var isHovering = false
	@State private var showPreview = false
	@State private var previewContext: FilePreviewContext?
	@State private var lineCount: Int?
	@State private var codemapLineCount: Int?
	@Environment(\.colorScheme) private var colorScheme
	@State private var cancellables: Set<AnyCancellable> = []

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private var fileHasSlices: Bool { props.hasSlices }

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 8) {
				HStack(spacing: 6) {
						Image(systemName: "doc.fill")
							.foregroundColor(.gray)
						Text(props.name)
							.font(fontPreset.font)
							.lineLimit(1)
							.truncationMode(.tail)
						
						modeBadge
						
						if props.showRootLabel {
							let labelColor = rootLabelColor(for: colorScheme)
							Text(props.rootFolderName)
								.font(.system(size: 10, weight: .medium))
								.padding(.horizontal, 6)
								.padding(.vertical, 2)
								.background(
									Capsule()
										.fill(labelColor)
								)
								.foregroundColor(.white)
								.shadow(color: labelColor.opacity(0.3), radius: 1, x: 0, y: 1)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					
					if isHovering {
						HStack(spacing: 0) {
							ActionButton(
								icon: "magnifyingglass",
								action: { openPreview() },
								tooltip: "Preview file contents"
							)
							Divider().frame(height: 16)
							ActionMenuButton(icon: "ellipsis", tooltip: "More actions") {
								Button {
									onCopy()
								} label: {
									Label("Copy File Contents", systemImage: "doc.on.clipboard")
								}
								
								Button {
									onCopyRelativePath()
								} label: {
									Label("Copy Relative Path", systemImage: "link")
								}
								
								Button {
									onCopyAbsolutePath()
								} label: {
									Label("Copy Absolute Path", systemImage: "link.circle")
								}
								
								Button {
									onOpenFile()
								} label: {
									Label("Open File", systemImage: "arrow.up.right.square")
								}
								
								Button {
									onRevealInFinder()
								} label: {
									Label("Reveal in Finder", systemImage: "folder")
								}
							}
							
							if codeMapUsage != .selected {
								Divider().frame(height: 16)
								switch props.mode {
								case .full:
									ActionButton(
										icon: "function",
										action: { onSetCodemap() },
										tooltip: props.canCodemap ? "Show as API only" : "No API available for this file",
										isDisabled: !props.canCodemap
									)
								case .slices:
									ActionButton(
										icon: "scissors.badge.ellipsis",
										action: { onClearSlices() },
										tooltip: "Clear line slices"
									)
								case .codemap:
									ActionButton(
										icon: "doc.text",
										action: { onSetFullContent() },
										tooltip: "Show full file"
									)
								}
							}
							
							Divider().frame(height: 16)
							ActionButton(
								icon: "xmark.circle",
								action: { onRemove() },
								tooltip: "Remove file from selection"
							)
						}
						.frame(width: codeMapUsage == .selected ? 84 : 112, height: 24)
						.background(Color.secondary.opacity(0.1))
						.cornerRadius(4)
						.clipShape(RoundedRectangle(cornerRadius: 4))
					}
				}
				.frame(height: 24)
				
				HStack(spacing: 4) {
					tokenInfoView
					if fileHasSlices, let display = props.compactSlicesDisplay {
						Text("•")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary.opacity(0.5))
						Text(display)
							.font(fontPreset.captionFont)
							.foregroundColor(.orange.opacity(0.8))
							.lineLimit(1)
							.truncationMode(.tail)
					}
					if props.mode == .codemap, let count = codemapLineCount {
						Text("•")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary.opacity(0.5))
						Text("\(count) lines")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.lineLimit(1)
					} else if let count = lineCount {
						Text("•")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary.opacity(0.5))
						Text("\(count) lines")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.lineLimit(1)
					}
				}
			}
			.padding(6)
			.background(backgroundColor)
			.cornerRadius(6)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Color.gray.opacity(0.5), lineWidth: 1)
			)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
			.onTapGesture { openPreview() }
			.onHover { hovering in
				// Avoid animating during grid reflow to prevent feedback loops.
				withTransaction(Transaction(animation: nil)) {
					isHovering = hovering
				}
			}
			.onAppear {
				setupSubscriptions()
			}
			.onChange(of: props.id) { _ in
				// Re-subscribe if the underlying file changes
				cancellables.removeAll()
				setupSubscriptions()
			}
			.onDisappear {
				cancellables.removeAll()
			}
			.contextMenu {
				if codeMapUsage != .selected {
					Button {
						onSetFullContent()
					} label: {
						Label("Show Full File", systemImage: "doc.text")
					}
					.disabled(props.mode == .full)
					
					Button {
						onSetCodemap()
					} label: {
						Label("Show As API Only", systemImage: "function")
					}
					.disabled(props.mode == .codemap || !props.canCodemap)
				}
				
				if fileHasSlices {
					Button {
						onClearSlices()
					} label: {
						Label("Clear Line Slices", systemImage: "scissors.badge.ellipsis")
					}
				}
				if codeMapUsage != .selected || fileHasSlices {
					Divider()
				}
				
				Button {
					onCopy()
				} label: {
					Label("Copy File Contents", systemImage: "doc.on.clipboard")
				}
				
				Button {
					onCopyRelativePath()
				} label: {
					Label("Copy Relative Path", systemImage: "link")
				}
				
				Button {
					onCopyAbsolutePath()
				} label: {
					Label("Copy Absolute Path", systemImage: "link.circle")
				}
				
				Button {
					onOpenFile()
				} label: {
					Label("Open File", systemImage: "arrow.up.right.square")
				}
				
				Button {
					onRevealInFinder()
				} label: {
					Label("Reveal in Finder", systemImage: "folder")
				}
				
				Button(role: .destructive) {
					onRemove()
				} label: {
					Label("Remove from Selection", systemImage: "xmark.circle")
				}
			}
			.popover(isPresented: $showPreview, arrowEdge: .bottom) {
				if let context = previewContext {
					FilePreviewPopover(
						file: context.file,
						fileSlices: context.slices,
						showCodeMap: props.mode == .codemap,
						showPreview: $showPreview
					)
				} else {
					Text("Loading…")
						.padding()
				}
			}
	}
	
	private func setupSubscriptions() {
		guard let file = resolveFile() else { return }
		
		// Seed current values
		self.lineCount = file.contentLineCount
		self.codemapLineCount = file.codemapLineCount
		
		// Subscribe to future updates
		file.$contentLineCount
			.receive(on: RunLoop.main)
			.sink { value in
				self.lineCount = value
			}
			.store(in: &cancellables)
		
		file.$codemapLineCount
			.receive(on: RunLoop.main)
			.sink { value in
				self.codemapLineCount = value
			}
			.store(in: &cancellables)
	}
	
	private func openPreview() {
		guard let context = preparePreview() else { return }
		previewContext = context
		showPreview = true
	}
	
	private var tokenInfoView: some View {
		Text(props.tokenDisplayString)
			.font(fontPreset.captionFont)
			.foregroundColor(.secondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.frame(maxWidth: .infinity, alignment: .leading)
	}
	
	private var backgroundColor: Color {
		if isHovering {
			return Color.gray.opacity(0.1)
		} else {
			return Color.clear
		}
	}
	
	@ViewBuilder
	private var modeBadge: some View {
		switch props.mode {
		case .codemap:
			Text("API")
				.font(.system(size: 9 * fontPreset.scaleFactor, weight: .medium))
				.padding(.horizontal, 4)
				.padding(.vertical, 1)
				.background(Color.blue.opacity(0.7))
				.foregroundColor(.white)
				.cornerRadius(3)
		case .slices:
			Image(systemName: "scissors")
				.font(.system(size: 9 * fontPreset.scaleFactor))
				.foregroundColor(.orange.opacity(0.7))
		case .full:
			EmptyView()
		}
	}
	
	private func rootLabelColor(for colorScheme: ColorScheme) -> Color {
		let isDark = colorScheme == .dark
		
		let lightColors: [Color] = [
			Color(red: 0.5, green: 0.6, blue: 0.7),
			Color(red: 0.5, green: 0.7, blue: 0.5),
			Color(red: 0.7, green: 0.6, blue: 0.4),
			Color(red: 0.6, green: 0.5, blue: 0.7),
			Color(red: 0.7, green: 0.5, blue: 0.6),
			Color(red: 0.4, green: 0.6, blue: 0.7)
		]
		
		let darkColors: [Color] = [
			Color(red: 0.4, green: 0.5, blue: 0.6),
			Color(red: 0.4, green: 0.6, blue: 0.4),
			Color(red: 0.6, green: 0.5, blue: 0.3),
			Color(red: 0.5, green: 0.4, blue: 0.6),
			Color(red: 0.6, green: 0.4, blue: 0.5),
			Color(red: 0.3, green: 0.5, blue: 0.6)
		]
		
		let colors = isDark ? darkColors : lightColors
		let hash = abs(props.rootFolderName.hashValue)
		return colors[hash % colors.count]
	}
}

struct SelectedTabBorder: Shape {
	var corners: RectCorner = .allCorners
	var isFirstTab: Bool = false
	
	func path(in rect: CGRect) -> Path {
		var path = Path()
		let topLeft = corners.contains(.topLeft)
		let topRight = corners.contains(.topRight)
		let width = rect.size.width
		let height = rect.size.height
		let radius: CGFloat = 16
		
		path.move(to: CGPoint(x: 0, y: height))
		path.addLine(to: CGPoint(x: 0, y: topLeft ? radius : 0))
		if topLeft {
			path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
		}
		path.addLine(to: CGPoint(x: width - (topRight ? radius : 0), y: 0))
		if topRight {
			path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
		}
		path.addLine(to: CGPoint(x: width, y: height))
		return path
	}
}

struct NoArrowDisclosureGroupStyle: DisclosureGroupStyle {
	func makeBody(configuration: Configuration) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				configuration.label
			}
			if configuration.isExpanded {
				configuration.content
			}
		}
	}
}

struct ActionButton: View {
	let icon: String
	let action: () -> Void
	var width: CGFloat = 28
	var height: CGFloat = 24
	var foregroundColor: Color = .primary
	var hoverForegroundColor: Color?
	var clickForegroundColor: Color?
	var useColorChange: Bool = false
	var tooltip: String?
	var isDisabled: Bool = false

	@State private var isHovered: Bool = false
	@State private var isPressed: Bool = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private var scaleFactor: CGFloat {
		fontPreset.scaleFactor
	}
	
	var body: some View {
		Button(action: {
			guard !isDisabled else { return }
			isPressed = true
			action()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				isPressed = false
			}
		}) {
			Image(systemName: icon)
				.foregroundColor(iconColor)
		}
		.frame(width: width * scaleFactor, height: height * scaleFactor)
		.contentShape(Rectangle())
		.buttonStyle(PlainButtonStyle())
		.background(isHovered ? Color.secondary.opacity(0.3) : Color.clear)
		.disabled(isDisabled)
		.onHover { hovering in
			// Simple, allocation-free hover tracking—no GeometryReader overlay.
			isHovered = hovering && !isDisabled
		}
		.hoverTooltip(tooltip)
	}
	
	private var iconColor: Color {
		if isDisabled { return Color.secondary.opacity(0.3) }
		if useColorChange {
			if isPressed { return (clickForegroundColor ?? foregroundColor).opacity(0.6) }
			if isHovered { return (hoverForegroundColor ?? foregroundColor).opacity(0.8) }
		}
		return foregroundColor
	}
}

struct ActionMenuButton<Content: View>: View {
	let icon: String
	let tooltip: String?
	let content: Content
	var width: CGFloat = 28
	var height: CGFloat = 24
	
	@State private var isHovered: Bool = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	private var scaleFactor: CGFloat { fontPreset.scaleFactor }
	
	init(
		icon: String,
		tooltip: String? = nil,
		@ViewBuilder content: () -> Content
	) {
		self.icon = icon
		self.tooltip = tooltip
		self.content = content()
	}
	
	var body: some View {
		Menu {
			content
		} label: {
			Image(systemName: icon)
				.foregroundColor(.primary)
		}
		.frame(width: width * scaleFactor, height: height * scaleFactor)
		.contentShape(Rectangle())
		.buttonStyle(PlainButtonStyle())
		.menuIndicator(.hidden)
		.menuStyle(.borderlessButton)
		.background(isHovered ? Color.secondary.opacity(0.3) : Color.clear)
		.onHover { hovering in
			isHovered = hovering
		}
		.hoverTooltip(tooltip)
	}
}
