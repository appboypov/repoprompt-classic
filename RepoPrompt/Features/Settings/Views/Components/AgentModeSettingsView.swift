//
//  AgentModeSettingsView.swift
//  RepoPrompt
//
//  Agent mode settings for Pro Edit
//

import SwiftUI

struct AgentModeSettingsView: View {
	@ObservedObject var promptViewModel: PromptViewModel

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Agent selection section
			VStack(alignment: .leading, spacing: 12) {
				Text("Agent Configuration")
					.font(.subheadline)
					.foregroundColor(.primary)

				Text("Runs a headless agent for each file to apply edits in parallel within a sandbox.")
					.font(.body)
					.foregroundColor(.secondary)

				// Agent picker
				HStack(spacing: 8) {
					Text("Agent")
						.font(.subheadline.bold())
						.fixedSize()

					Picker("", selection: $promptViewModel.proEditAgentKind) {
						ForEach(promptViewModel.availableProEditAgentKinds, id: \.self) { agent in
							Text(agent.displayName).tag(agent)
						}
					}
					.pickerStyle(.menu)
					.help("Select which MCP agent to use for delegate edits")
				}

				// Model picker
				HStack(spacing: 8) {
					Text("Model")
						.font(.subheadline.bold())
						.fixedSize()

					StableMenuButton(items: proEditModelMenuItems) {
						AgentModelSelectionSummaryLabel(
							agentKind: promptViewModel.proEditAgentKind,
							rawModel: promptViewModel.proEditAgentModelRaw,
							title: promptViewModel.proEditAgentModelDisplayName,
							iconFont: .caption
						)
					}
					.help("Select the model for the chosen agent")
				}
			}
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			.cornerRadius(8)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
			)
		}
	}

	private func proEditModelMenuItems() -> [StableMenuItem] {
		AgentModelStableMenuItems.modelItems(
			agentKind: promptViewModel.proEditAgentKind,
			options: proEditModelOptions,
			selectedAgent: promptViewModel.proEditAgentKind,
			selectedModelRaw: promptViewModel.proEditAgentModelRaw
		) { _, selectedOption in
			promptViewModel.selectProEditAgentModel(rawModel: selectedOption.rawValue)
		}
	}

	private var proEditModelOptions: [AgentModelOption] {
		promptViewModel.proEditModelOptions(for: promptViewModel.proEditAgentKind)
	}
}
