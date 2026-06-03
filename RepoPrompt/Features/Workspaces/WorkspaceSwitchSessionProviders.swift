import Foundation

@MainActor
final class ChatWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
	private weak var workspaceManager: WorkspaceManagerViewModel?
	private weak var chatViewModel: ChatViewModel?

	init(workspaceManager: WorkspaceManagerViewModel, chatViewModel: ChatViewModel) {
		self.workspaceManager = workspaceManager
		self.chatViewModel = chatViewModel
	}

	func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
		let count = activeChatCount()
		guard count > 0 else { return [] }
		return [WorkspaceSwitchSessionItem(
			id: "chat",
			count: count,
			singularLabel: "active chat session",
			pluralLabel: "active chat sessions"
		)]
	}

	func cancelSwitchSessions() async {
		guard let workspaceManager, let chatViewModel else { return }
		guard activeChatCount() > 0 else { return }

		await chatViewModel.cancelAllActiveSessionStreams()
		workspaceManager.setActiveChatTabs([])
		workspaceManager.isChatBusy = false
	}

	private func activeChatCount() -> Int {
		guard let workspaceManager else { return 0 }
		return max(workspaceManager.tabsWithActiveChat.count, workspaceManager.isChatBusy ? 1 : 0)
	}
}

@MainActor
final class ContextAndDiscoverWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
	private weak var discoverAgentViewModel: DiscoverAgentViewModel?

	init(discoverAgentViewModel: DiscoverAgentViewModel) {
		self.discoverAgentViewModel = discoverAgentViewModel
	}

	func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
		let count = activeContextBuilderCount()
		guard count > 0 else { return [] }
		return [WorkspaceSwitchSessionItem(
			id: "context-builder",
			count: count,
			singularLabel: "active context builder session",
			pluralLabel: "active context builder sessions"
		)]
	}

	func cancelSwitchSessions() async {
		await discoverAgentViewModel?.cancelAllActiveRuns()
	}

	private func activeContextBuilderCount() -> Int {
		let discoverTabs = discoverAgentViewModel?.tabsWithActiveDiscoverRun ?? []
		let planTabs = discoverAgentViewModel?.tabsWithActivePlanGeneration ?? []
		return discoverTabs.union(planTabs).count
	}
}

@MainActor
final class AgentModeWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
	private weak var agentModeViewModel: AgentModeViewModel?

	init(agentModeViewModel: AgentModeViewModel) {
		self.agentModeViewModel = agentModeViewModel
	}

	func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
		let count = activeAgentCount()
		guard count > 0 else { return [] }
		return [WorkspaceSwitchSessionItem(
			id: "agent-mode",
			count: count,
			singularLabel: "active agent session",
			pluralLabel: "active agent sessions"
		)]
	}

	func cancelSwitchSessions() async {
		guard let agentModeViewModel else { return }
		let activeTabs = agentModeViewModel.tabsWithActiveAgentRun
		for tabID in activeTabs {
			await agentModeViewModel.cancelAgentRun(tabID: tabID, waitForCleanup: false)
		}
	}

	private func activeAgentCount() -> Int {
		agentModeViewModel?.tabsWithActiveAgentRun.count ?? 0
	}
}
