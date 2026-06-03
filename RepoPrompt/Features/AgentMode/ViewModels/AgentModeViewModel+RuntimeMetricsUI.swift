import Foundation

@MainActor
extension AgentModeViewModel {
	func syncRuntimeMetricsUIState(liveSelectedFileCount: Int? = nil) {
		ui.runtimeMetrics.update(
			transcriptSnapshot: activeTranscriptAnalyticsSnapshot,
			codexUsage: contextUsage,
			liveSelectedFileCount: liveSelectedFileCount,
			selectedAgent: selectedAgent,
			selectedModelRaw: selectedModelRaw
		)
	}
}
