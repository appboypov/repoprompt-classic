import SwiftUI

enum AgentProviderSettingsMenuAction {
	static let title = "Connect more CLI providers…"
	static let imageSystemName = "terminal"

	static func shouldShow(availableAgents: [DiscoverAgentKind]) -> Bool {
		AgentModelCatalog.hasUnconfiguredSupportedCLIProviders(availableAgents: availableAgents)
	}

	static func open(windowID: Int) {
		NotificationCenter.default.post(
			name: .showCLIProvidersTab,
			object: nil,
			userInfo: ["windowID": windowID]
		)
	}

	static func appendStableMenuItem(
		to items: inout [StableMenuItem],
		windowID: Int,
		availableAgents: [DiscoverAgentKind]
	) {
		guard shouldShow(availableAgents: availableAgents) else { return }
		if !items.isEmpty {
			items.append(.separator)
		}
		items.append(stableMenuItem(windowID: windowID))
	}

	static func stableMenuItem(windowID: Int) -> StableMenuItem {
		StableMenuItem.action(
			title,
			imageSystemName: imageSystemName
		) {
			open(windowID: windowID)
		}
	}
}

struct AgentProviderSettingsMenuSection: View {
	let availableAgents: [DiscoverAgentKind]
	let windowID: Int

	var body: some View {
		if AgentProviderSettingsMenuAction.shouldShow(availableAgents: availableAgents) {
			if !availableAgents.isEmpty {
				Divider()
			}
			Button {
				AgentProviderSettingsMenuAction.open(windowID: windowID)
			} label: {
				Label(AgentProviderSettingsMenuAction.title, systemImage: AgentProviderSettingsMenuAction.imageSystemName)
			}
		}
	}
}
