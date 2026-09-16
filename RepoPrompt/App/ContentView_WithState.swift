//
//  ContentView_WithState.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-24.
//

import SwiftUI

/// Renders the runtime the shell currently shows. The shell owns every `WindowState`;
/// this view only attaches the native window and swaps content when the visible runtime changes.
struct ContentView_WithState: View {
	@EnvironmentObject var versionManager: VersionManager
	@EnvironmentObject var windowStatesManager: WindowStatesManager
	@EnvironmentObject var shellViewModel: WorkspaceShellViewModel
	@Environment(\.openWindow) private var openWindow
	
	var body: some View {
		Group {
			if let runtime = shellViewModel.contentRuntime {
				ContentView(windowState: runtime)
					.environmentObject(runtime)
					.environmentObject(versionManager)
					.id(runtime.windowID)
			} else {
				Color.clear
			}
		}
			.background(
				WindowAccessor { newWindow in
					// IMPORTANT: do not mutate SwiftUI @State here.
					guard let newWindow else { return }
					shellViewModel.attachNativeWindow(newWindow)
				}
			)
			.onAppear {
				// Install the openWindow action into AppWindowOpener for programmatic window creation
				AppWindowOpener.shared.install {
					openWindow(id: "main")
				}
			}
		// Transition notice
			.sheet(
				isPresented: Binding(
					get: { versionManager.shouldShowTransitionNotice },
					set: { newValue in
						if newValue == false {
							versionManager.dismissTransitionNotice()
						}
					}
				)
			) {
				TransitionNoticeView {
					versionManager.dismissTransitionNotice()
				}
			}
	}
}
