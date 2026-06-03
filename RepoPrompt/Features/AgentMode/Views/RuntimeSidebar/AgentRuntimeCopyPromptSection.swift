import SwiftUI

struct AgentRuntimeCopyPromptSection: View {
	@ObservedObject var promptManager: PromptViewModel

	var body: some View {
		AgentRuntimeSectionCard(
			title: "Copy Prompt",
			subtitle: "Uses current copy preset"
		) {
			Button {
				promptManager.performCopyUsingCurrentPreset(openApplyXMLTab: false)
			} label: {
				Label("Copy Prompt", systemImage: "doc.on.doc")
					.font(.system(size: 11, weight: .medium))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.small)
		}
	}
}
