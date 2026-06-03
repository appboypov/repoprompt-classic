import SwiftUI

struct AgentRuntimeContextBuilderSection: View {
	@ObservedObject var discoverAgentVM: DiscoverAgentViewModel
	let currentTabID: UUID?

	@AppStorage("agent.runtime.sidebar.builder.expanded")
	private var isExpanded: Bool = true

	private var isRunningForTab: Bool {
		guard let currentTabID else { return false }
		return discoverAgentVM.tabsWithActiveDiscoverRun.contains(currentTabID)
	}

	private var subtitle: String {
		isRunningForTab ? "Running" : "Idle"
	}

	var body: some View {
		AgentRuntimeSectionCard(
			title: "Discovery Agent",
			subtitle: subtitle,
			trailing: {
				Button {
					withAnimation(.easeInOut(duration: 0.15)) {
						isExpanded.toggle()
					}
				} label: {
					Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		) {
			if isExpanded {
				if !discoverAgentVM.agentLog.isEmpty {
					VStack(alignment: .leading, spacing: 4) {
						ForEach(Array(discoverAgentVM.agentLog.suffix(5))) { entry in
							AgentLogEntryRowView(entry: entry, style: .compact)
						}
					}
					if discoverAgentVM.toolCallCount > 0 {
						Text("\(discoverAgentVM.toolCallCount) tool calls")
							.font(.system(size: 10))
							.foregroundStyle(.secondary)
							.padding(.top, 2)
					}
				} else {
					Text("No recent discovery activity for this tab.")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}
