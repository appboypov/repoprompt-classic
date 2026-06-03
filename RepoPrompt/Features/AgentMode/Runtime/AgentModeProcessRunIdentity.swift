import Foundation

@MainActor
enum AgentModeProcessRunIdentity {
	static func existingProcessRunID(for session: AgentModeViewModel.TabSession) -> UUID? {
		session.runID
	}

	static func startFreshProcessRun(for session: AgentModeViewModel.TabSession) -> UUID {
		let runID = UUID()
		session.runID = runID
		return runID
	}

	static func clearProcessRunID(for session: AgentModeViewModel.TabSession) {
		session.runID = nil
	}
}
