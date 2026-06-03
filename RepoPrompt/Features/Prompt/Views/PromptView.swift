import SwiftUI
import Combine

// Notification to switch to the Apply XML tab
extension Notification.Name {
	/// Tells the file selection components to jump to the **Apply XML** tab.
	static let switchToApplyXMLTab = Notification.Name("switchToApplyXMLTab")
}


struct PromptView: View {
	@ObservedObject var promptManager: PromptViewModel
	@ObservedObject var fileManager: RepoFileManagerViewModel
	let discoverAgentViewModel: DiscoverAgentViewModel
	@ObservedObject var windowState: WindowState
	@ObservedObject var diffViewModel: DiffViewModel
	let windowID: Int
	@Binding var currentTab: PromptTab
	@Binding var currentView: ViewType
	@Binding var showSettings: Bool
	
	@State private var isCopying: Bool = false
	@State private var copyComplete: Bool = false
	@State private var lastTokenCount: Int = 0
	@State private var queryIdentifier = UUID()
	@State private var selectedFile: FileViewModel?
	@State private var showClipboardSettings = false
	@Binding var showSettingsPopover: Bool
	@State private var showAIQuerySettings = false
	@State private var showWarning = false
	
	@State private var showXMLClipboardSettings = false
	// showCustomizationPanel removed - now handled by UnifiedPresetBar
	@StateObject private var selectedFilesPanelViewModel: SelectedFilesPanelViewModel
	
	// Read the same collapsed state as InstructionsView to coordinate layout
	// Default is false (expanded) - license-based default applied in InstructionsView.onAppear
	@AppStorage("instructionsViewCollapsed") private var instructionsCollapsed: Bool = false

	var selectFileForPreview: (FileViewModel?) -> Void
	init(
		promptManager: PromptViewModel,
		fileManager: RepoFileManagerViewModel,
		discoverAgentViewModel: DiscoverAgentViewModel,
		windowState: WindowState,
		diffViewModel: DiffViewModel,
		windowID: Int,
		currentTab: Binding<PromptTab>,
		currentView: Binding<ViewType>,
		showSettings: Binding<Bool>,
		showSettingsPopover: Binding<Bool>,
		selectFileForPreview: @escaping (FileViewModel?) -> Void
	) {
		self.promptManager = promptManager
		self.fileManager = fileManager
		self.discoverAgentViewModel = discoverAgentViewModel
		self.windowState = windowState
		self.diffViewModel = diffViewModel
		self.windowID = windowID
		self._currentTab = currentTab
		self._currentView = currentView
		self._showSettings = showSettings
		self._showSettingsPopover = showSettingsPopover
		self.selectFileForPreview = selectFileForPreview
		self._selectedFilesPanelViewModel = StateObject(wrappedValue: SelectedFilesPanelViewModel(fileManager: fileManager, promptVM: promptManager))
	}
	
	var body: some View {
		VStack(spacing: 8) {
			// Main content area with 50/50 split
			VStack(spacing: 0) {
				// Instructions section - collapses to give more space to file selection
				InstructionsView(
					promptManager: promptManager,
					onSendToChat: { sendPromptToAI() },
					windowID: windowID
				)
				// When collapsed, don't force infinity height so file selection can expand
				.frame(maxHeight: instructionsCollapsed ? nil : .infinity)
				.padding(.horizontal)
				.padding(.top, 8)
				.animation(.easeInOut(duration: 0.2), value: instructionsCollapsed)
				
				// File tabs selector - takes from shared space
				FilesTabSelector(
					selectedTab: Binding(
						get: { promptManager.activeFilesTab },
						set: { promptManager.setActiveFilesTab($0, source: .user) }
					),
					fileCount: selectedFilesPanelViewModel.snapshot.totalFileCount,
					codemapCount: selectedFilesPanelViewModel.snapshot.apiCodemapCount
				)
				.padding(.horizontal)
				.padding(.top, 16)
				
				// File selection section - 50% minus tab height
				TabbedFileSelectionContent(
					fileManager: fileManager,
					promptManager: promptManager,
					discoverAgentViewModel: discoverAgentViewModel,
					windowState: windowState,
					diffViewModel: diffViewModel,
					selectedFilesPanelViewModel: selectedFilesPanelViewModel,
					selectedFile: $selectedFile,
					selectFileForPreview: selectFileForPreview,
					availableHeight: 600,
					activeTab: promptManager.activeFilesTab
				)
				.frame(maxHeight: .infinity)
				.padding(.horizontal)
			}
			.frame(maxHeight: .infinity)
			
			// Bottom buttons - outside the 50/50 split
			bottomButtons
				.padding(.horizontal)
				.padding(.vertical, 8)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onReceive(
			NotificationCenter.default.publisher(
				for: .switchToApplyXMLTab,
				object: nil
			)
		) { note in
			guard
				let id = note.userInfo?["windowID"] as? Int,
				id == windowID
			else { return }
			withAnimation(.easeInOut) {
				promptManager.setActiveFilesTab(.apply, source: .user)
				diffViewModel.clearXMLInput()
			}
		}
	}
	
	private var bottomButtons: some View {
		VStack(alignment: .leading, spacing: 0) {
			UnifiedPresetBar(
				promptVM: promptManager,
				tokenCounter: promptManager.tokenCountingViewModel,
				fileManager: fileManager,
				gitViewModel: promptManager.gitViewModel,
				onCopyNow: {
					promptManager.performCopyUsingCurrentPreset()
				}
			)
		}
	}

	
	private func resetCopyButtonIfNeeded(_ newValue: Int) {
		if newValue != lastTokenCount {
			lastTokenCount = newValue
			if copyComplete {
				withAnimation {
					copyComplete = false
				}
			}
		}
	}
	
	private func performCopy() {
		isCopying = true
		promptManager.copyToClipboard()
		withAnimation {
			copyComplete = true
		}
	}
	
	private func performXMLCopy() {
		// Copy the XML-formatted prompt to the clipboard
		promptManager.copyXMLInstructions(promptManager.promptText)
		
		// Tell *this* window's file-selector to open the "Apply XML" tab.
		// The `object:` parameter scopes delivery to only the promptManager
		// that originated the event, so other windows stay untouched.
		NotificationCenter.default.post(
			name: .switchToApplyXMLTab,
			object: nil,
			userInfo: ["windowID": windowID]
		)
	}
	
	private func shouldShowWarning() -> Bool {
		let tokenCount = Int(promptManager.tokenCountingViewModel.tokenCount.replacingOccurrences(of: "k", with: "")) ?? 0
		let fileCount = fileManager.selectedFiles.count
		return tokenCount > 50 || fileCount > 25
	}
	
	private func sendPromptToAI() {
		Task {
			if await !promptManager.hasValidModelSelected() {
				await MainActor.run {
					NotificationCenter.default.post(
						name: .showAPISettingsTab,
						object: nil,
						userInfo: ["windowID": windowID]
					)
				}
			} else {
				await MainActor.run {
					promptManager.sendPromptToChatView()
					currentTab = .chat
				}
			}
		}
	}
}
