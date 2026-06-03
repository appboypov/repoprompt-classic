import SwiftUI

enum FilterScope: String, CaseIterable, Identifiable {
	case local = "Local Folder"
	case global = "Global Default"
	
	var id: String { rawValue }
}

// Provide explicit Equatable conformance:
extension FilterScope: Equatable {
	static func == (lhs: FilterScope, rhs: FilterScope) -> Bool {
		lhs.rawValue == rhs.rawValue
	}
}

struct FilterOverlayView: View {
	@Binding var isVisible: Bool
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject private var globalSettings = GlobalSettingsStore.shared
	
	// Which tab: Local vs Global?
	@State private var filterScope: FilterScope = .local
	
	// Local folder picker and path
	@State private var selectedFolderIndex = 0
	
	// Separate drafts so switching scopes does not discard edits.
	@State private var localEditorContent: String = ""
	@State private var globalEditorContent: String = ""
	@State private var localOriginalContent: String = ""
	@State private var globalOriginalContent: String = ""
	
	// Track if a local .repo_ignore already exists
	@State private var localFileExists: Bool = false
	
	// Optional ephemeral “Saved!” message
	@State private var showSavedIndicator = false
	
	private var rootFolders: [FolderViewModel] {
		fileManager.visibleRootFolders
	}
	
	private var editorBinding: Binding<String> {
		Binding(
			get: {
				filterScope == .local ? localEditorContent : globalEditorContent
			},
			set: { newValue in
				if filterScope == .local {
					localEditorContent = newValue
				} else {
					globalEditorContent = newValue
				}
			}
		)
	}
	
	private var hasLocalChanges: Bool {
		localEditorContent != localOriginalContent
	}
	
	private var hasGlobalChanges: Bool {
		globalEditorContent != globalOriginalContent
	}
	
	private var isDirty: Bool {
		hasLocalChanges || hasGlobalChanges
	}
	
	private var dirtyDescription: String {
		let dirtyScopes = [
			hasLocalChanges ? "Local" : nil,
			hasGlobalChanges ? "Global" : nil
		].compactMap { $0 }
		return dirtyScopes.isEmpty ? "" : "Unsaved: \(dirtyScopes.joined(separator: ", "))"
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Ignore Patterns")
				.font(.headline)
			
			Text("Edit ignore patterns. Local patterns are additive to global defaults from your settings. Use negative patterns (starting with '!') in .repo_ignore files to override global patterns when needed.")
				.font(.caption)
			
			// Scope picker
			Picker("Filter Scope", selection: $filterScope) {
				ForEach(FilterScope.allCases) { scope in
					Text(scope.rawValue).tag(scope)
				}
			}
			.pickerStyle(SegmentedPickerStyle())
			.onChange(of: filterScope) { _, _ in
				showSavedIndicator = false
			}
			
			if filterScope == .local {
				if localFileExists {
					Text("Local scope edits this folder’s .repo_ignore file. Global defaults still apply unless overridden with negative patterns.")
						.font(.footnote)
						.foregroundColor(.secondary)
				} else {
					Text("No local .repo_ignore exists yet. Add local-only patterns here, or leave this empty to use global defaults only.")
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			} else {
				Text("Global defaults apply to every workspace. Local .repo_ignore files are saved separately and can add or override these patterns.")
					.font(.footnote)
					.foregroundColor(.secondary)
			}
			
			if filterScope == .local {
				Group {
					if rootFolders.isEmpty {
						Text("No folders loaded")
							.foregroundColor(.secondary)
							.padding(.top, 4)
							.disabled(true)
					} else {
						Picker("Select Folder", selection: $selectedFolderIndex) {
							ForEach(rootFolders.indices, id: \.self) { idx in
								Text(rootFolders[idx].name).tag(idx)
							}
						}
						.pickerStyle(MenuPickerStyle())
						.onChange(of: selectedFolderIndex) { _, _ in
							loadLocalContent()
						}
					}
					
					// Show path
					Text(localRepoIgnorePath() ?? "No folder selected")
						.font(.system(size: 14))
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.disabled(rootFolders.isEmpty)
			}
			
			// Main editor
			TextEditor(text: editorBinding)
				.frame(height: 300)
				.background(Color(NSColor.textBackgroundColor))
				.cornerRadius(5)
				.font(.system(size: 14))
				.overlay(
					RoundedRectangle(cornerRadius: 5)
						.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
				)
			
			// Fixed-height area for status messages
			ZStack(alignment: .leading) {
				if filterScope == .local && !localFileExists && !localEditorContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					Text("A new .repo_ignore file will be created upon save.")
						.font(.footnote)
						.foregroundColor(.orange)
				}
				
				if isDirty {
					HStack(spacing: 6) {
						Text(dirtyDescription)
							.font(.footnote)
							.foregroundColor(.red)
					}
				}
				
				if showSavedIndicator {
					HStack {
						Spacer()
						Text("Saved!")
							.font(.footnote)
							.foregroundColor(.green)
					}
					.padding(.trailing, 4)
					.transition(.opacity)
				}
			}
			.frame(height: 20)
			
			// Buttons
			HStack {
				Button("Cancel") {
					isVisible = false
				}
				.buttonStyle(CustomButtonStyle())
				
				Button("Save") {
					saveContent()
				}
				.buttonStyle(CustomButtonStyle())
			}
			.frame(maxWidth: .infinity, alignment: .center)
		}
		.padding()
		.frame(width: 500)
		.background(Color(NSColor.controlBackgroundColor))
		.cornerRadius(10)
		.shadow(radius: 10)
		.onAppear {
			loadContent()
			// Auto-pick local if .repo_ignore is found for selected folder
			let path = localRepoIgnorePath()
			if let path = path, FileManager.default.fileExists(atPath: path) {
				filterScope = .local
			} else {
				filterScope = .global
			}
		}
	}
	
	// Helper to get local .repo_ignore path
	private func localRepoIgnorePath() -> String? {
		guard selectedFolderIndex < rootFolders.count else { return nil }
		let folder = rootFolders[selectedFolderIndex]
		return (folder.fullPath as NSString).appendingPathComponent(".repo_ignore")
	}
	
	private func loadContent() {
		showSavedIndicator = false
		loadGlobalContent()
		loadLocalContent()
	}
	
	private func loadGlobalContent() {
		let defaults = globalSettings.globalIgnoreDefaults()
		globalEditorContent = defaults
		globalOriginalContent = defaults
	}
	
	private func loadLocalContent() {
		localFileExists = false
		showSavedIndicator = false
		guard !rootFolders.isEmpty, let path = localRepoIgnorePath() else {
			localEditorContent = ""
			localOriginalContent = ""
			return
		}
		
		if FileManager.default.fileExists(atPath: path) {
			localFileExists = true
			do {
				let fileText = try String(contentsOfFile: path, encoding: .utf8)
				localEditorContent = fileText
				localOriginalContent = fileText
			} catch {
				print("Error reading .repo_ignore: \(error)")
				localEditorContent = ""
				localOriginalContent = ""
			}
		} else {
			// No local file: keep the local draft empty so users don't accidentally
			// duplicate global defaults into .repo_ignore.
			localEditorContent = ""
			localOriginalContent = ""
		}
	}
	
	private func saveContent() {
		do {
			try saveGlobalContentIfNeeded()
			try saveLocalContentIfNeeded()
			
			if hasGlobalChanges {
				globalSettings.postFileSystemPreferencesDidChange(key: "file_system.global_ignore_defaults")
			}
			if hasLocalChanges {
				fileManager.requestFileSystemSettingsRefresh()
			}
			
			originalsMatchDrafts()
			showSavedIndicator = true
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
				withAnimation {
					showSavedIndicator = false
					isVisible = false
				}
			}
		} catch {
			print("Error saving ignore patterns: \(error)")
		}
	}
	
	private func saveGlobalContentIfNeeded() throws {
		guard hasGlobalChanges else { return }
		globalSettings.setGlobalIgnoreDefaults(globalEditorContent)
	}
	
	private func saveLocalContentIfNeeded() throws {
		guard hasLocalChanges else { return }
		guard let path = localRepoIgnorePath() else { return }
		
		let shouldWriteLocalFile = localFileExists || !localEditorContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		guard shouldWriteLocalFile else { return }
		
		try localEditorContent.write(toFile: path, atomically: true, encoding: .utf8)
		localFileExists = true
	}
	
	private func originalsMatchDrafts() {
		globalOriginalContent = globalEditorContent
		localOriginalContent = localEditorContent
	}
}
