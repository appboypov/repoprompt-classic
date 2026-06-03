#if DEBUG
import SwiftUI

struct AgentChatStressHarnessPanel: View {
	@ObservedObject var harness: AgentChatStressHarness
	let currentTabID: UUID?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(harness.statusText)
				.font(.system(size: 12, weight: .semibold))
				.accessibilityIdentifier("agentStress.status")

			HStack(spacing: 8) {
				Button("Start") { harness.start(currentTabID: currentTabID) }
					.accessibilityIdentifier("agentStress.start")
				Button("Pause") { harness.pause() }
					.accessibilityIdentifier("agentStress.pause")
				Button("Resume") { harness.resume(currentTabID: currentTabID) }
					.accessibilityIdentifier("agentStress.resume")
				Button("Reset") { harness.reset(currentTabID: currentTabID) }
					.accessibilityIdentifier("agentStress.reset")
				Button("Detach") { harness.requestForceDetach() }
					.accessibilityIdentifier("agentStress.panelForceDetach")
			}
			.buttonStyle(.bordered)

			telemetryBlock(title: "Telemetry", json: harness.telemetryJSONString, identifier: "agentStress.telemetry")
			telemetryBlock(title: "Grouping", json: harness.groupingJSONString, identifier: "agentStress.grouping")
			telemetryBlock(title: "Events", json: harness.recentEventsText.isEmpty ? "(no events)" : harness.recentEventsText, identifier: "agentStress.events")
		}
		.padding(12)
		.frame(width: 420, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
		)
		.shadow(color: .black.opacity(0.12), radius: 10, y: 4)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("agentStress.panel")
	}

	private func telemetryBlock(title: String, json: String, identifier: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.secondary)
			Text(json)
				.font(.system(size: 10, design: .monospaced))
				.textSelection(.enabled)
				.lineLimit(4)
				.frame(maxWidth: .infinity, alignment: .leading)
				.accessibilityIdentifier(identifier)
				.accessibilityValue(json)
		}
	}
}
#endif
