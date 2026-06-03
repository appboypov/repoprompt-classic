import SwiftUI

struct AgentRuntimeSectionCard<Content: View, Trailing: View>: View {
	let title: String
	let subtitle: String?
	@ViewBuilder let trailing: () -> Trailing
	@ViewBuilder let content: () -> Content

	init(
		title: String,
		subtitle: String? = nil,
		@ViewBuilder content: @escaping () -> Content
	) where Trailing == EmptyView {
		self.title = title
		self.subtitle = subtitle
		self.trailing = { EmptyView() }
		self.content = content
	}

	init(
		title: String,
		subtitle: String? = nil,
		@ViewBuilder trailing: @escaping () -> Trailing,
		@ViewBuilder content: @escaping () -> Content
	) {
		self.title = title
		self.subtitle = subtitle
		self.trailing = trailing
		self.content = content
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .center, spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.system(size: 12, weight: .semibold))
					if let subtitle, !subtitle.isEmpty {
						Text(subtitle)
							.font(.system(size: 10))
							.foregroundStyle(.secondary)
					}
				}
				Spacer(minLength: 8)
				trailing()
			}

			content()
		}
		.padding(10)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.stroke(Color.secondary.opacity(0.15), lineWidth: 1)
		)
	}
}
