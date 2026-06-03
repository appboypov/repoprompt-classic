//
//  TabbedFileSelectionContent.swift
//  RepoPrompt
//
//  Content area of file selection without tabs
//

import SwiftUI

struct TabbedFileSelectionContent: View {
    @ObservedObject var fileManager: RepoFileManagerViewModel
    @ObservedObject var promptManager: PromptViewModel
    let discoverAgentViewModel: DiscoverAgentViewModel
    @ObservedObject var windowState: WindowState
    @ObservedObject var diffViewModel: DiffViewModel
    @ObservedObject var selectedFilesPanelViewModel: SelectedFilesPanelViewModel
    @Binding var selectedFile: FileViewModel?
    var selectFileForPreview: (FileViewModel?) -> Void
    var availableHeight: CGFloat
    let activeTab: FilesTab
    
    private var contentBackgroundColor: Color {
        //isDarkMode() ? Color(NSColor.windowBackgroundColor) : Color(white: 0.85)
		Color(.secondarySystemFill)
    }
    
    private var borderColor: Color {
        isDarkMode() ? Color.gray.opacity(0.5) : Color(NSColor.systemGray)
    }
    
    func isDarkMode() -> Bool {
		/*
        if (!isTransparent()) {
            return true
        }
		*/
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    
	/*
    func isTransparent() -> Bool {
        let useTransparency = UserDefaults.standard.object(forKey: "useTransparency") as? Bool ?? true
        return useTransparency
    }
	*/
    
    var body: some View {
        ZStack {
            RoundedCorner(radius: 16, corners: [.bottomLeft, .bottomRight, .topRight])
                .fill(.regularMaterial)
            
            VStack(spacing: 0) {
                if activeTab == .selected {
                    SelectedFilesContentView(
                        fileManager: fileManager,
                        promptManager: promptManager,
                        selectedFile: $selectedFile,
                        selectFileForPreview: selectFileForPreview,
                        windowID: windowState.windowID,
                        panelViewModel: selectedFilesPanelViewModel
                    )
                } else if activeTab == .context {
                    GeometryReader { geo in
						DiscoverAgentView(
							viewModel: discoverAgentViewModel,
							chatViewModel: windowState.chatViewModel,
							windowID: windowState.windowID,
							availableWidth: geo.size.width
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
							if windowState.kind != .discoverAgent {
								windowState.kind = .discoverAgent
                            }
                        }
                        .onDisappear {
							if windowState.kind == .discoverAgent {
								windowState.kind = .standard
							}
                        }
                    }
                } else { // .apply case
                    GeometryReader { geo in
                        DiffView(viewModel: diffViewModel,
                                promptViewModel: promptManager,
                                availableWidth: geo.size.width,
                                availableHeight: geo.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(8)
            
            RoundedCorner(radius: 16, corners: [.bottomLeft, .bottomRight, .topRight])
                .stroke(borderColor, lineWidth: 0.5)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .switchToApplyXMLTab,
                object: promptManager
            )
        ) { _ in
            // This is now handled in PromptView
        }
    }
}
