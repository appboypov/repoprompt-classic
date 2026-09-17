import SwiftUI

/// The window toolbar for the shown runtime: mode toggle, recommendations and MCP server.
/// Declared once by the shell root, so the window never carries one set per prepared runtime.
struct WorkspaceRuntimeToolbar: ToolbarContent {
	@ObservedObject var windowState: WindowState
	@Binding var showMCPServerPopover: Bool
	@Binding var showRecommendationsPopover: Bool

	var body: some ToolbarContent {
		ToolbarItem(placement: .automatic) {
			AgentModeToggle(mode: $windowState.uiMode)
		}
		ToolbarItem(placement: .automatic) {
			RecommendationToolbarButtonView(
				viewModel: windowState.recommendationWizardViewModel,
				showPopover: $showRecommendationsPopover
			)
		}
		ToolbarItem(placement: .automatic) {
			MCPServerToggleView(windowState: windowState, showPopover: $showMCPServerPopover)
		}
	}
}
