import SwiftUI

/// One runtime's content tree with the environment the legacy scene used to provide.
struct WorkspaceRuntimeRootView: View {
	let windowState: WindowState

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		ContentView(windowState: windowState)
			.environmentObject(windowState)
			.environmentObject(WindowStatesManager.shared)
			.environmentObject(fontScale)
			.environment(\.font, fontScale.preset.font)
			.environment(\.repoPromptFontScalePreset, fontScale.preset)
	}
}
