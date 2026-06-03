//
//  ProEditSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-04.
//


import SwiftUI

struct ProEditSettingsView: View {
	@ObservedObject var promptViewModel: PromptViewModel
	var showStatusIndicator: Bool = true // Show the agent mode status by default

	// Mode selection
	private enum ProEditMode: String, CaseIterable, Identifiable {
		case agent = "Agent"
		case model = "Model"
		var id: String { rawValue }
	}

	@AppStorage("proEditSelectedMode") private var selectedModeRawValue: String = ProEditMode.model.rawValue
	private var selectedMode: ProEditMode {
		get { ProEditMode(rawValue: selectedModeRawValue) ?? .model }
		set { selectedModeRawValue = newValue.rawValue }
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				// Legacy banner — Pro Edit has been superseded by Agent Mode.
				legacyBanner

				// Header with mode picker
				VStack(alignment: .leading, spacing: 8) {
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text("Pro Edit Settings")
								.font(.headline)
	
							Spacer()
	
							if selectedMode == .model {
								Button("Auto Configure Models") {
									promptViewModel.autoConfigureProEditSettings()
								}
								.buttonStyle(CustomButtonStyle())
							}
						}
						
						// Status indicator for agent mode (only show if showStatusIndicator is true)
						if showStatusIndicator && selectedMode == .agent {
							HStack(spacing: 6) {
								Image(systemName: "checkmark.circle.fill")
									.foregroundColor(.green)
									.font(.system(size: 12))
								Text("Pro Edits currently using Agent mode")
									.font(.caption)
									.foregroundColor(.green)
							}
						}
					}

					// Description
					Text("Pro Edit mode uses your selected AI model to plan edits, while delegate edit agents or models apply those edits simultaneously.")
						.font(.caption)
						.foregroundColor(.secondary)

					// Mode picker (tab toggle)
					modePicker
						.padding(.top, 4)
				}

				// Mode-specific content
				Group {
					switch selectedMode {
					case .agent:
						AgentModeSettingsView(promptViewModel: promptViewModel)
					case .model:
						ModelModeSettingsView(promptViewModel: promptViewModel)
					}
				}
				.transition(.opacity)
			}
			.padding()
		}
		.onChange(of: selectedMode) { _, newMode in
			// Sync the agent mode toggle with the selected tab
			withAnimation(.easeInOut(duration: 0.2)) {
				promptViewModel.proEditAgentMode = (newMode == .agent)
			}
		}
		.onAppear {
			// Initialize selected mode based on current agent mode setting
			selectedModeRawValue = promptViewModel.proEditAgentMode ? ProEditMode.agent.rawValue : ProEditMode.model.rawValue
		}
	}

	// Legacy-mode banner explaining that MCP/Agent Mode edits have superseded Pro Edit.
	private var legacyBanner: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "clock.arrow.circlepath")
				.font(.body)
				.foregroundColor(.orange)
				.padding(.top, 2)

			VStack(alignment: .leading, spacing: 4) {
				Text("Pro Edit")
					.font(.subheadline.weight(.semibold))
					.foregroundColor(.primary)

				Text("Pro Edit still works for multi-model delegated edits. For day-to-day editing, use Agent Mode — MCP-driven edits cover the same ground with your connected CLI providers.")
					.font(.caption)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer(minLength: 0)
		}
		.padding(12)
		.background(Color.orange.opacity(0.08))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(Color.orange.opacity(0.35), lineWidth: 1)
		)
		.cornerRadius(8)
	}

	// Mode picker (inspired by ContextBuilderView)
	private var modePicker: some View {
		HStack(spacing: 4) {
			ForEach(ProEditMode.allCases) { mode in
				Button(action: {
					selectedModeRawValue = mode.rawValue
				}) {
					Text(mode.rawValue)
						.font(.caption)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(selectedMode == mode ? Color.accentColor : Color.clear)
						.foregroundColor(selectedMode == mode ? .white : .primary)
						.cornerRadius(4)
				}
				.buttonStyle(.plain)
				.help(mode == .agent ? "Use MCP agents for delegate edits" : "Use AI models directly for delegate edits")
			}
		}
		.padding(3)
		.background(Color(NSColor.controlBackgroundColor))
		.cornerRadius(6)
	}
}
