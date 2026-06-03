import Foundation

extension AgentModeViewModel {
	func makeStatusPillsSnapshot() -> AgentStatusPillsSnapshot {
		AgentStatusPillsSnapshot(
			currentTabID: currentTabID,
			selectedWorkflow: selectedWorkflow,
			stagedSlashCommand: stagedSlashCommandProps(tabID: currentTabID),
			selectedAgent: selectedAgent,
			autoEditPermissionGuidance: autoEditPermissionGuidance,
			runState: runState,
			autoEditEnabled: autoEditEnabled,
			interviewFirst: interviewFirst,
			activeAgentSessionID: activeSession?.activeAgentSessionID,
			activeRunID: activeSession?.runID
		)
	}

	func syncStatusPillsUIState() {
		ui.statusPills.update(makeStatusPillsSnapshot())
	}

	func setInterviewFirst(_ enabled: Bool) {
		guard interviewFirst != enabled else { return }
		interviewFirst = enabled
		syncStatusPillsUIState()
	}

	func toggleInterviewFirst() {
		setInterviewFirst(!interviewFirst)
	}
}
