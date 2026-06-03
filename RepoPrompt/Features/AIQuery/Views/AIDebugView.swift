import SwiftUI
import AppKit

struct AIDebugView: View {
	@ObservedObject var viewModel: AIResponseViewModel
	@State private var isExpanded = true
	
	var body: some View {
		VStack {
			Button(action: { isExpanded.toggle() }) {
				Text(isExpanded ? "Hide Debug Info" : "Show Debug Info")
			}
			.padding()
			
			if isExpanded {
				VStack(alignment: .leading) {
					Text("Raw AI Output:")
						.font(.headline)
					ScrollView {
						Text(viewModel.rawOutput)
							.font(.system(.body, design: .monospaced))
							.padding()
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: 200)
					
					if let summary = viewModel.overallSummary {
						Text("Overall Summary:")
							.font(.headline)
						Text(summary)
							.padding()
					}
				}
				.background(Color(NSColor.textBackgroundColor))
				.cornerRadius(8)
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.stroke(Color.secondary, lineWidth: 1)
				)
				.padding()
			}
		}
	}
}
