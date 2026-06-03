import Combine
import Foundation

struct AgentStatusPillsSnapshot: Equatable {
	let currentTabID: UUID?
	let selectedWorkflow: AgentWorkflowDefinition?
	let stagedSlashCommand: AgentStagedSlashCommandProps?
	let selectedAgent: DiscoverAgentKind
	let autoEditPermissionGuidance: AgentModeViewModel.AutoEditPermissionGuidance?
	let runState: AgentSessionRunState
	let autoEditEnabled: Bool
	let interviewFirst: Bool
	let activeAgentSessionID: UUID?
	let activeRunID: UUID?

	static let empty = AgentStatusPillsSnapshot(
		currentTabID: nil,
		selectedWorkflow: nil,
		stagedSlashCommand: nil,
		selectedAgent: .claudeCode,
		autoEditPermissionGuidance: nil,
		runState: .idle,
		autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
		interviewFirst: false,
		activeAgentSessionID: nil,
		activeRunID: nil
	)
}

@MainActor
final class AgentStatusPillsUIStore: ObservableObject {
	@Published private(set) var snapshot: AgentStatusPillsSnapshot
	@Published private(set) var revision: UInt64 = 0

	init(snapshot: AgentStatusPillsSnapshot = .empty) {
		self.snapshot = snapshot
	}

	func update(_ nextSnapshot: AgentStatusPillsSnapshot) {
		guard snapshot != nextSnapshot else {
			#if DEBUG
			AgentModePerfDiagnostics.recordStoreUpdate("statusPills", published: false)
			AgentModeLayoutHotspotDiagnostics.increment("store.statusPills.suppressed", tabID: nextSnapshot.currentTabID)
			#endif
			return
		}
		snapshot = nextSnapshot
		revision &+= 1
		#if DEBUG
		AgentModeLayoutHotspotDiagnostics.increment("store.statusPills.publish", tabID: snapshot.currentTabID)
		AgentModePerfDiagnostics.recordStoreUpdate(
			"statusPills",
			published: true,
			details: [
				"revision": String(revision),
				"runState": String(describing: snapshot.runState),
				"tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID)
			]
		)
		#endif
	}
}
