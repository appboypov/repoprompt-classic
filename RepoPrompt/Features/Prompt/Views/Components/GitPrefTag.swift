import SwiftUI

struct GitPrefTag: View {
    @ObservedObject var gitViewModel: GitViewModel
	@ObservedObject var promptManager: PromptViewModel
	var context: SettingsContext = .copy
	var gitDiffTokenCount: Int = 0
	var isLocked: Bool = false
	var presetOverride: String? = nil  // Name of preset overriding git settings

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
    
    @State private var showPopover = false
    @State private var isHovering = false
    
	private var currentGitMode: GitDiffInclusionMode {
		switch context {
		case .copy:
			return promptManager.gitDiffInclusionModeForCopy
		case .chat:
			let chatMode = promptManager.gitDiffInclusionModeForChat
			if chatMode != .none {
				return chatMode
			}
			if let presetInclusion = promptManager.currentChatPreset().gitInclusion {
				return mapPresetMode(presetInclusion)
			}
			return chatMode
		}
	}
	
	private var gitModeBinding: Binding<GitDiffInclusionMode> {
		Binding(
			get: { currentGitMode },
			set: { newValue in
				switch context {
				case .copy:
					promptManager.updateGitInclusion(newValue)
				case .chat:
					promptManager.updateGitInclusionForChat(newValue)
				}
				promptManager.markSettingsDirty()
				gitViewModel.gitDiffInclusionMode = newValue
			}
		)
	}
	
	private func mapPresetMode(_ inclusion: GitInclusion) -> GitDiffInclusionMode {
		switch inclusion {
		case .none: return .none
		case .selected: return .selectedFiles
		case .complete: return .all
		}
	}
    
    private var gitTooltip: String {
        var tooltip = "Include git diffs in your prompt to help AI models understand recent changes.\n"
        tooltip += "Diffs show exactly what was modified, added, or deleted—useful for code reviews,\n"
        tooltip += "debugging, and giving context about work in progress."
        
        return tooltip
    }
    
    var body: some View {
        GitTagContent(
            fontPreset: fontPreset,
            isHovering: isHovering,
			isActive: presetOverride != nil || currentGitMode != .none,
            selectedRootFolder: gitViewModel.selectedRootFolder,
            unstagedCount: gitViewModel.unstagedFiles.count,
			diffMode: currentGitMode,
			gitDiffTokenCount: gitDiffTokenCount,
			isLocked: isLocked
        )
		.opacity(gitViewModel.gitEnabledRootFolders.isEmpty ? 0.5 : 1.0)
		.allowsHitTesting(!gitViewModel.gitEnabledRootFolders.isEmpty)
        .onTapGesture {
			if !gitViewModel.gitEnabledRootFolders.isEmpty {
                showPopover.toggle()
            }
        }
        .hoverTooltip(gitTooltip)
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            GitPopoverContent(
                gitViewModel: gitViewModel,
				promptManager: promptManager,
				gitModeBinding: gitModeBinding,
				fontPreset: fontPreset,
				presetOverride: presetOverride
            )
            .onAppear {
                gitViewModel.isPopoverVisible = true
                Task {
                    await gitViewModel.fetchUnstagedFiles(trigger: .popoverOpen)
                }
            }
            .onDisappear {
                gitViewModel.isPopoverVisible = false
            }
        }
        .onHover { hovering in
			if !gitViewModel.gitEnabledRootFolders.isEmpty {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovering = hovering
                }
            }
        }
		.onAppear {
			gitViewModel.gitDiffInclusionMode = currentGitMode
		}
		.onChange(of: promptManager.gitDiffInclusionModeForCopy) { _, newValue in
			if context == .copy {
				gitViewModel.gitDiffInclusionMode = newValue
			}
		}
		.onChange(of: promptManager.gitDiffInclusionModeForChat) { _, newValue in
			if context == .chat {
				gitViewModel.gitDiffInclusionMode = newValue
			}
		}
    }
}

// MARK: - Tag Content Component
struct GitTagContent: View {
    let fontPreset: FontScalePreset
    let isHovering: Bool
    let isActive: Bool
    let selectedRootFolder: FolderViewModel?
    let unstagedCount: Int
    let diffMode: GitDiffInclusionMode
	let gitDiffTokenCount: Int
	var isLocked: Bool = false
	
	private var tagHorizontalPadding: CGFloat { fontPreset.scaledClamped(8, min: 8, max: 12) }
	private var tagVerticalPadding: CGFloat { fontPreset.scaledClamped(4, min: 4, max: 7) }
	private var tagMinHeight: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 36) }
	private var tagCornerRadius: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 20) }
    
    var body: some View {
        HStack(spacing: fontPreset.scaledClamped(8, min: 8, max: 10)) {
            Text("Git")
                .font(fontPreset.standardFont)
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            
            GitStatusIndicator(
                fontPreset: fontPreset,
                unstagedCount: unstagedCount,
                hasRepo: selectedRootFolder != nil,
                diffMode: diffMode
            )
            
			/*
			// Show token count when git diff is active
			if diffMode != .none && gitDiffTokenCount > 0 {
				Text("~\(String(format: "%.1fk", Double(gitDiffTokenCount) / 1000.0))")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			*/
        }
        .padding(.horizontal, tagHorizontalPadding)
        .padding(.vertical, tagVerticalPadding)
		.frame(minHeight: tagMinHeight)
        .background(backgroundView)
        .cornerRadius(tagCornerRadius)
        .overlay(borderView)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isActive {
            Color.blue.opacity(isHovering ? 0.2 : 0.1)
        } else {
            Color.gray.opacity(isHovering ? 0.2 : 0.1)
        }
    }
    
    @ViewBuilder
    private var borderView: some View {
        RoundedRectangle(cornerRadius: tagCornerRadius)
			.stroke(isActive ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
    }
}

// MARK: - Status Indicator Component
struct GitStatusIndicator: View {
    let fontPreset: FontScalePreset
    let unstagedCount: Int
    let hasRepo: Bool
    let diffMode: GitDiffInclusionMode
    
    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: fontPreset.scaledClamped(12, min: 12, max: 15)))
            .frame(width: fontPreset.scaledClamped(16, min: 16, max: 21), height: fontPreset.scaledClamped(16, min: 16, max: 21))
            .foregroundColor(iconColor)
    }
    
    private var iconName: String {
        if !hasRepo {
            return "minus.circle"
        }
        
        // Show different icons based on diff mode
        switch diffMode {
        case .none:
            return unstagedCount > 0 ? "circle.fill" : "circle"
        case .selectedFiles:
            return unstagedCount > 0 ? "smallcircle.filled.circle" : "smallcircle.circle"
        case .all:
            return unstagedCount > 0 ? "largecircle.fill.circle" : "circle.circle"
        }
    }
    
    private var iconColor: Color {
        if !hasRepo {
            return .secondary
        }
        
        // Active color when diff mode is enabled
        if diffMode != .none {
            return .blue
        }
        
		// Draw attention when there are unstaged changes
		//return unstagedCount > 0 ? .orange : .secondary
		return	.secondary
    }
}

// MARK: - Popover Content Component
struct GitPopoverContent: View {
    @ObservedObject var gitViewModel: GitViewModel
	@ObservedObject var promptManager: PromptViewModel
	let gitModeBinding: Binding<GitDiffInclusionMode>
    let fontPreset: FontScalePreset
	var presetOverride: String? = nil
    
    var body: some View {
		VStack(spacing: 0) {
            // Header and controls
            GitControls(
                gitViewModel: gitViewModel,
				promptManager: promptManager,
				gitModeBinding: gitModeBinding,
				fontPreset: fontPreset,
				presetOverride: presetOverride
            )
			.padding(.horizontal, 20)
			.padding(.top, 20)
            
			// Search box — always present to keep layout height stable.
			// Disabled/toned down while an error is showing.
			GitSearchBox(
				gitViewModel: gitViewModel,
				fontPreset: fontPreset
			)
			.padding(.horizontal, 20)
			.padding(.vertical, 12)
			.opacity(gitViewModel.errorMessage == nil ? 1.0 : 0.5)
			.disabled(gitViewModel.errorMessage != nil)
			
			// Content area — keep a fixed list-height and overlay any error/loading.
			ZStack {
                GitFileSelectionList(
                    gitViewModel: gitViewModel,
                    fontPreset: fontPreset
                )
				.disabled(gitViewModel.errorMessage != nil)
				.opacity(gitViewModel.isLoadingStatus && gitViewModel.unstagedFiles.isEmpty ? 0.5 : 1.0)

				if gitViewModel.isLoadingStatus && gitViewModel.unstagedFiles.isEmpty {
					// Show loading indicator only when we have no cached data to show
					VStack(spacing: 8 * fontPreset.scaleFactor) {
						ProgressView()
							.scaleEffect(0.8)
						Text("Loading changes...")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.transition(.opacity)
				} else if let error = gitViewModel.errorMessage {
					GitErrorOverlay(message: error, fontPreset: fontPreset)
						.transition(.opacity)
				}
            }
			.frame(height: 250 * fontPreset.scaleFactor)
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
        }
		.frame(width: 450 * fontPreset.scaleFactor)
		// REMOVED: .animation modifier on popover content causes crashes due to SwiftUI/AppKit interaction bug
		// The error overlay already has .transition(.opacity) which provides sufficient visual feedback
    }
}

// Lightweight overlay that shows an error without affecting layout height.
private struct GitErrorOverlay: View {
	let message: String
	let fontPreset: FontScalePreset
	var body: some View {
		VStack(spacing: 8 * fontPreset.scaleFactor) {
			if message.contains("Not a git repository") {
				Text("This folder is not a git repository")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			} else {
				Text(message)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(
			// Transparent background still captures the full ZStack area,
			// ensuring taps do not hit the list beneath when an error is shown.
			Rectangle().fill(Color.clear).contentShape(Rectangle())
		)
	}
}

// MARK: - Search Box Component
struct GitSearchBox: View {
	@ObservedObject var gitViewModel: GitViewModel
	let fontPreset: FontScalePreset

	@State private var localSearch: String = ""
	@State private var debounceTask: Task<Void, Never>? = nil
	
	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass")
				.foregroundColor(searchIconColor)
				.font(.system(size: 14))
			
			TextField("Search files", text: $localSearch)
				.textFieldStyle(PlainTextFieldStyle())
				.font(.system(size: 13))
				.foregroundColor(Color(NSColor.labelColor))
				.onSubmit {
					// Keep focus on search field when pressing Enter
				}
				.onKeyPress(.escape) {
					if !localSearch.isEmpty {
						localSearch = ""
						gitViewModel.clearFileSearch()
						return .handled
					}
					return .ignored
				}
				.onChange(of: localSearch) { _, newValue in
					// Debounce search to avoid filtering on every keystroke
					debounceTask?.cancel()
					gitViewModel.isFilteringPaused = true
					debounceTask = Task { [weak gitViewModel] in
						try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
						guard !Task.isCancelled else { return }
						await MainActor.run {
							gitViewModel?.fileSearchText = newValue
							gitViewModel?.isFilteringPaused = false
						}
					}
				}
			
			// Show loading indicator when filtering is paused or clear button
			if gitViewModel.isFilteringPaused {
				ProgressView()
					.progressViewStyle(CircularProgressViewStyle())
					.scaleEffect(0.5)
					.frame(width: 12, height: 12)
			} else if !localSearch.isEmpty {
				Button(action: {
					localSearch = ""
					gitViewModel.clearFileSearch()
				}) {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
						.font(.system(size: 12))
				}
				.buttonStyle(PlainButtonStyle())
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(Color.clear)
		.cornerRadius(6)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(borderColor, lineWidth: 0.5)
		)
		.onAppear { localSearch = gitViewModel.fileSearchText }
	}
	
	private var searchIconColor: Color {
		if gitViewModel.isFilteringPaused {
			return .secondary
		} else if !localSearch.isEmpty {
			return .accentColor
		} else {
			return Color(NSColor.labelColor).opacity(0.6)
		}
	}
	
	private var borderColor: Color {
		if !localSearch.isEmpty {
			return .accentColor.opacity(0.5)
		} else {
			return Color(NSColor.systemGray).opacity(0.75)
		}
	}
}

// MARK: - Controls Component
struct GitControls: View {
    @ObservedObject var gitViewModel: GitViewModel
	@ObservedObject var promptManager: PromptViewModel
	let gitModeBinding: Binding<GitDiffInclusionMode>
    let fontPreset: FontScalePreset
	var presetOverride: String? = nil
    
	// State for artifact generation
	@State private var isGeneratingArtifacts = false
	@State private var artifactGenerationError: String?
	@State private var lastGeneratedSnapshotID: String?
    
    private func getDiffModeTooltip() -> String {
        return """
        None: No git diffs included in prompts
        Selected: Include only diffs for checked files below
        All: Include diffs for all unstaged files
        """
    }
    
	private func getArtifactsTooltip() -> String {
		"Generate diff artifacts to _git_data/ for manual chunk selection in code reviews. Creates MAP.txt overview, manifest.json, and individual .patch files you can selectively include.\n\nRequires diff inclusion mode to be set to 'Selected' or 'All'."
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12 * fontPreset.scaleFactor) {
            
			// Always render root folder section with consistent height
			VStack(alignment: .leading, spacing: 8 * fontPreset.scaleFactor) {
				HStack {
					if gitViewModel.gitEnabledRootFolders.isEmpty {
						Text("No folders available")
							.font(fontPreset.subheadlineFont)
							.foregroundColor(.secondary)
					} else if gitViewModel.gitEnabledRootFolders.count == 1, let singleRoot = gitViewModel.gitEnabledRootFolders.first {
                        Text(singleRoot.name)
                            .font(fontPreset.subheadlineFont)
                            .foregroundColor(.primary)
					} else {
						Text("Root Folder:")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
                    }
                    
					Spacer()
					
					if let branch = gitViewModel.currentBranch, !gitViewModel.gitEnabledRootFolders.isEmpty {
						Text(branch)
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.secondary.opacity(0.1))
							.cornerRadius(6)
					}
                }
				
				// Picker or explainer text - always reserve the space
				Group {
					if gitViewModel.gitEnabledRootFolders.count > 1 {
						Picker("Root Folder", selection: $gitViewModel.selectedRootFolder) {
							ForEach(gitViewModel.gitEnabledRootFolders, id: \.id) { folder in
								Text(folder.name)
									.font(fontPreset.standardFont)
									.tag(folder as FolderViewModel?)
							}
						}
						.pickerStyle(MenuPickerStyle())
					} else if !gitViewModel.gitEnabledRootFolders.isEmpty {
						Text("Generate diffs from your current state using git to help with code reviews")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				.frame(minHeight: 32 * fontPreset.scaleFactor) // Reserve consistent height
            }
			
			Divider()
            
			// Git diff inclusion mode - always render with consistent height
			Group {
				if gitViewModel.hasValidRepository {
					if let presetName = presetOverride {
						// Show preset-controlled banner instead of picker
						HStack(spacing: 6) {
							Image(systemName: "wand.and.stars")
								.font(.system(size: 10))
								.foregroundColor(.blue.opacity(0.8))
							Text("\(presetName) Preset Active")
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
							Spacer()
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(Color.blue.opacity(0.08))
						.cornerRadius(6)
					} else {
						// Show normal picker when not preset-controlled
						Picker("Include diff in prompt:", selection: gitModeBinding) {
							ForEach(GitDiffInclusionMode.allCases, id: \.self) { mode in
								Text(mode.displayName)
									.tag(mode)
							}
						}
						.pickerStyle(SegmentedPickerStyle())
						.hoverTooltip(getDiffModeTooltip())
					}
				}
			}
			.frame(minHeight: 28 * fontPreset.scaleFactor) // Ensure consistent height for both states
			
			// Branch selection for diff comparison - always render but disable when not applicable
			VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
				Text("Compare working changes with:")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
				
				HStack(spacing: 8 * fontPreset.scaleFactor) {
					Picker("", selection: $gitViewModel.selectedDiffBranch) {
						// Show HEAD with current branch name
						if let currentBranch = gitViewModel.currentBranch {
							Text("HEAD (\(currentBranch))")
                                .font(fontPreset.standardFont)
								.tag("HEAD")
						} else {
							Text("HEAD")
								.font(fontPreset.standardFont)
								.tag("HEAD")
                        }
						
                        Divider()
                        
						// Local branches section
						ForEach(gitViewModel.availableBranches, id: \.name) { branch in
                            HStack {
								Text(branch.name)
                                    .font(fontPreset.standardFont)
								if branch.isCurrent {
									Text("(current)")
										.font(fontPreset.captionFont)
										.foregroundColor(.secondary)
								}
                            }
							.tag(branch.name)
                        }
                        
						// Remote branches section (if any exist)
						if !gitViewModel.availableRemoteBranches.isEmpty {
							Divider()
							
							ForEach(gitViewModel.availableRemoteBranches, id: \.name) { remoteBranch in
								HStack {
									Image(systemName: "cloud")
										.font(fontPreset.captionFont)
										.foregroundColor(.secondary)
									Text(remoteBranch.name)
										.font(fontPreset.standardFont)
								}
								.tag(remoteBranch.name)
                            }
                        }
						
						// Tags section (if any exist)
						if !gitViewModel.availableTags.isEmpty {
							Divider()
							
							ForEach(gitViewModel.availableTags, id: \.name) { tag in
								HStack {
									Image(systemName: "tag.fill")
										.font(fontPreset.captionFont)
										.foregroundColor(.secondary)
									Text(tag.name)
										.font(fontPreset.standardFont)
								}
								.tag(tag.name)
							}
						}
                    }
					.pickerStyle(MenuPickerStyle())
					.labelsHidden()
					.disabled(!gitViewModel.hasValidRepository)
					.opacity(!gitViewModel.hasValidRepository ? 0.5 : 1.0)
					
					Spacer()
					
					// Generate artifacts button with info tooltip
					Button(action: {
						generateArtifacts()
					}) {
						HStack(spacing: 6) {
							if isGeneratingArtifacts {
								ProgressView()
									.scaleEffect(0.6)
									.frame(width: 14, height: 14)
							} else {
								Image(systemName: "doc.badge.gearshape")
									.font(.system(size: 12))
							}
							Text(lastGeneratedSnapshotID != nil ? "Regenerate Artifacts" : "Generate Artifacts")
								.font(fontPreset.captionFont)
						}
                    }
					.buttonStyle(CustomButtonStyle())
					.disabled(!canGenerateArtifacts || isGeneratingArtifacts)
					.hoverTooltip(getArtifactsTooltip())
					
					// Info tooltip icon
					Image(systemName: "info.circle")
						.font(.system(size: 12))
						.foregroundColor(.secondary)
						.hoverTooltip(getArtifactsTooltip())
                }
                
				// Show error or success feedback below the row
				if let error = artifactGenerationError {
					Text(error)
						.font(fontPreset.captionFont)
						.foregroundColor(.red)
						.lineLimit(1)
				} else if let snapshotID = lastGeneratedSnapshotID {
					HStack(spacing: 4) {
						Image(systemName: "checkmark.circle.fill")
							.font(.system(size: 10))
                            .foregroundColor(.green)
						Text("Created")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
                    }
                }
            }
			.frame(minHeight: 52 * fontPreset.scaleFactor)
        }
    }
    
	private var canGenerateArtifacts: Bool {
		gitViewModel.hasValidRepository && gitModeBinding.wrappedValue != .none
    }
    
	private func generateArtifacts() {
		isGeneratingArtifacts = true
		artifactGenerationError = nil
		
		Task { @MainActor in
			defer { isGeneratingArtifacts = false }
			
			do {
				let manifest = try await promptManager.publishGitDiffArtifacts(
					inclusionMode: gitModeBinding.wrappedValue,
					vsBranch: gitViewModel.selectedDiffBranch,
					publishMode: .standard
				)
				lastGeneratedSnapshotID = manifest.snapshotID
				artifactGenerationError = nil
			} catch {
				lastGeneratedSnapshotID = nil
				artifactGenerationError = error.localizedDescription
			}
        }
    }
}

// MARK: - File Selection List Component
struct GitFileSelectionList: View {
    @ObservedObject var gitViewModel: GitViewModel
    let fontPreset: FontScalePreset
    @State private var showCopiedFeedback = false
    @State private var isCopying = false
    @State private var showCopiedAllFeedback = false
    @State private var isCopyingAll = false
    
    private var areAllSelected: Bool {
		!gitViewModel.filteredUnstagedFiles.isEmpty &&
		gitViewModel.filteredUnstagedFiles.allSatisfy { file in
            gitViewModel.isFileSelected(file.path)
        }
    }
    
    private var hasSelectedFiles: Bool {
		gitViewModel.filteredUnstagedFiles.contains { file in
            gitViewModel.isFileSelected(file.path)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with title and stats
            VStack(spacing: 6 * fontPreset.scaleFactor) {
                // First line: Title, count, and stats
                HStack(spacing: 8 * fontPreset.scaleFactor) {
                    // Title
                    Text("Pending changes")
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.primary)
                    
                    // Show subtle refresh indicator when updating with cached data
                    if gitViewModel.isLoadingStatus && !gitViewModel.unstagedFiles.isEmpty {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    
                    // File count
                    if gitViewModel.unstagedFiles.count > 0 {
                        Text("\(gitViewModel.unstagedFiles.count)")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .hoverTooltip("Total unstaged files")
                    }
                    
                    // Stats (+/-)
                    if gitViewModel.totalAdditions > 0 {
                        Text("+\(gitViewModel.totalAdditions)")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.green)
                            .hoverTooltip("Lines added")
                    }
                    if gitViewModel.totalDeletions > 0 {
                        Text("-\(gitViewModel.totalDeletions)")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.red)
                            .hoverTooltip("Lines deleted")
                    }
                    
                    Spacer()
                }
                
                // Second line: Action buttons
                HStack(spacing: 8 * fontPreset.scaleFactor) {
                    Button(areAllSelected ? "Deselect All" : "Select All") {
                        Task {
                            if areAllSelected {
								await gitViewModel.removeFilteredUnstagedFromFileManager()
                            } else {
								await gitViewModel.addFilteredUnstagedToFileManager()
                            }
                        }
                    }
                    .font(fontPreset.captionFont)
                    .buttonStyle(CustomButtonStyle())
					.disabled(gitViewModel.isBulkSelectionRunning) // Prevent overlapping bulk ops
                    .hoverTooltip(areAllSelected ? "Remove all files from selection" : "Add all unstaged files to selection")
                    
                    Button(showCopiedFeedback ? "Copied!" : "Copy Selected") {
                        isCopying = true  // Disable button immediately

                        Task { @MainActor in
                            let success = await gitViewModel.copySelectedDiff()

                            isCopying = false  // Re-enable button

                            if success {
                                // Avoid SwiftUI animations inside popovers (known to trigger layout/constraints recursion)
                                showCopiedFeedback = true

                                // Reset feedback after 1.5 seconds
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    showCopiedFeedback = false
                                }
                            }
                        }
                    }
                    .font(fontPreset.captionFont)
                    .buttonStyle(CustomButtonStyle())
                    .disabled(!hasSelectedFiles || showCopiedFeedback || isCopying)
                    .opacity(showCopiedFeedback ? 0.7 : 1.0)
                    .hoverTooltip("Copy diff of selected files")
                    
                    Button(showCopiedAllFeedback ? "Copied!" : "Copy All") {
                        isCopyingAll = true  // Disable button immediately

                        Task { @MainActor in
                            let success = await gitViewModel.copyAllDiff()

                            isCopyingAll = false  // Re-enable button

                            if success {
                                // Avoid SwiftUI animations inside popovers (known to trigger layout/constraints recursion)
                                showCopiedAllFeedback = true

                                // Reset feedback after 1.5 seconds
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    showCopiedAllFeedback = false
                                }
                            }
                        }
                    }
                    .font(fontPreset.captionFont)
                    .buttonStyle(CustomButtonStyle())
                    .disabled(gitViewModel.unstagedFiles.isEmpty || showCopiedAllFeedback || isCopyingAll)
                    .opacity(showCopiedAllFeedback ? 0.7 : 1.0)
                    .hoverTooltip("Copy diff of all working tree files")
                    
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            
            Divider()
            
            // File list with checkboxes
            ScrollView {
                LazyVStack(alignment: .leading,
                           spacing: 2 * fontPreset.scaleFactor) {
					ForEach(gitViewModel.filteredUnstagedFiles, id: \.path) { file in
                        GitFileCheckboxRowWrapper(
                            gitViewModel: gitViewModel,
                            file: file,
                            fontPreset: fontPreset
                        )
                    }
                }
                .padding(8)
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Wrapper to ensure proper state updates
struct GitFileCheckboxRowWrapper: View {
    @ObservedObject var gitViewModel: GitViewModel
    let file: VCSUncommittedFile
    let fontPreset: FontScalePreset
    
    @State private var isSelected: Bool = false
    
    var body: some View {
        GitFileCheckboxRow(
            file: file,
            isSelected: isSelected,
            fontPreset: fontPreset,
            onToggle: { newValue in
                Task {
                    if newValue {
                        await gitViewModel.addFileToSelection(file.path)
                    } else {
                        await gitViewModel.removeFileFromSelection(file.path)
                    }
                    // Update local state after the action
                    isSelected = gitViewModel.isFileSelected(file.path)
                }
            }
        )
        .equatable()
        .onAppear {
            // Initialize state on appear
            isSelected = gitViewModel.isFileSelected(file.path)
        }
        .onChange(of: gitViewModel.fileSelectionStates) { _, _ in
            // Update state when selection states change
            isSelected = gitViewModel.isFileSelected(file.path)
        }
    }
}

// MARK: - File Checkbox Row Component
struct GitFileCheckboxRow: View, Equatable {
    let file: VCSUncommittedFile
    let isSelected: Bool
    let fontPreset: FontScalePreset
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Button(action: {
            onToggle(!isSelected)
        }) {
            HStack(spacing: 8 * fontPreset.scaleFactor) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14 * fontPreset.scaleFactor))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                Text(statusSymbol)
                    .font(.system(size: 12 * fontPreset.scaleFactor,
                                   weight: .medium,
                                   design: .monospaced))
                    .foregroundColor(statusColor)
                    //.frame(width: 20 * fontPreset.scaleFactor, alignment: .leading)
                
                // Combined additions/deletions in a more compact format
                HStack(spacing: 2) {
                    if let adds = file.additions, adds > 0 {
                        Text("+\(adds)")
                            .font(.system(size: 10 * fontPreset.scaleFactor,
                                           design: .monospaced))
                            .foregroundColor(.green)
                    }
                    if let dels = file.deletions, dels > 0 {
                        Text("-\(dels)")
                            .font(.system(size: 10 * fontPreset.scaleFactor,
                                           design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
				//.frame(width: 40 * fontPreset.scaleFactor, alignment: .leading)
                
                Text(file.path)
                    .font(.system(size: 11 * fontPreset.scaleFactor,
                                   design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var statusSymbol: String {
        switch file.status.trimmingCharacters(in: .whitespaces) {
        case "M": return "M"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        case "U": return "U"
        case "??": return "A"   // untracked → show as Added
        case "!": return "!"
        default: return file.status
        }
    }
    
    private var statusColor: Color {
        switch file.status.trimmingCharacters(in: .whitespaces) {
        case "M": return .secondary    // Modified
        case "A": return .green.opacity(0.8)     // Added
        case "D": return .red.opacity(0.8)       // Deleted
        case "R": return .blue.opacity(0.8)      // Renamed
        case "C": return .blue.opacity(0.8)      // Copied
        case "U": return .purple.opacity(0.8)    // Unmerged
        case "??": return .green.opacity(0.8)  // Untracked → treat like Added
        case "!": return .red.opacity(0.8)       // Ignored
        default: return .secondary
        }
    }
}

extension GitFileCheckboxRow {
    static func == (lhs: GitFileCheckboxRow, rhs: GitFileCheckboxRow) -> Bool {
        // Compare stable fields; ignore action closure
        let l = lhs.file
        let r = rhs.file
        return lhs.isSelected == rhs.isSelected &&
               lhs.fontPreset.scaleFactor == rhs.fontPreset.scaleFactor &&
               l.path == r.path &&
               l.status == r.status &&
               l.additions == r.additions &&
               l.deletions == r.deletions
    }
}
