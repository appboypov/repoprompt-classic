import SwiftUI

struct ReadOnlyInputBox: View {
	let text: String
	let placeholder: String
	var minHeight: CGFloat = 30
	var multiline: Bool = false

	private var displayText: String {
		text.isEmpty ? placeholder : text
	}

	private var foregroundColor: Color {
		text.isEmpty ? .secondary : .primary
	}

	var body: some View {
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 6)
				.fill(Color(NSColor.controlBackgroundColor))

			RoundedRectangle(cornerRadius: 6)
				.stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)

			Text(displayText)
				.foregroundColor(foregroundColor)
				.lineLimit(multiline ? nil : 1)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.textSelection(.enabled)
		}
		.frame(minHeight: minHeight, alignment: .topLeading)
	}
}
