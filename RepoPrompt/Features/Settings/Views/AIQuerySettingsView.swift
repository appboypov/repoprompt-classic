import SwiftUI

struct AIQuerySettingsView: View {
	@ObservedObject var promptViewModel: PromptViewModel
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				AIQueryBasicSettingsView(promptViewModel: promptViewModel)
				
				Divider()
				
				ProEditSettingsView(promptViewModel: promptViewModel)
			}
			.padding()
		}
		.frame(width: 475)
	}
}
