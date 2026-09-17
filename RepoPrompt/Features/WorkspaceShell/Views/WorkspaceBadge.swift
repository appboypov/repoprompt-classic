import SwiftUI

enum WorkspaceBadgeKind: CaseIterable {
	case unavailable
	case runningAgent

	var symbolName: String {
		switch self {
		case .unavailable: return "folder.badge.questionmark"
		case .runningAgent: return "circle.fill"
		}
	}

	var color: Color {
		switch self {
		case .unavailable: return .secondary
		case .runningAgent: return .green
		}
	}

	var label: String {
		switch self {
		case .unavailable: return WorkspaceShellStrings.unavailable
		case .runningAgent: return WorkspaceShellStrings.runningAgent
		}
	}

	var help: String {
		switch self {
		case .unavailable: return WorkspaceShellStrings.unavailableHelp
		case .runningAgent: return WorkspaceShellStrings.runningAgentHelp
		}
	}
}

enum WorkspaceBadgeSize {
	/// Icon and short text, for the expanded row.
	case label
	/// 8px dot, for the collapsed tile corner.
	case dot
}

/// One state marker on a sidebar row.
struct WorkspaceBadge: View {
	let kind: WorkspaceBadgeKind
	let size: WorkspaceBadgeSize

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		switch size {
		case .label:
			HStack(spacing: 3) {
				Image(systemName: kind.symbolName)
					.font(.system(size: kind == .runningAgent ? 6 : 10))
				Text(kind.label)
					.font(fontScale.preset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
					.lineLimit(1)
			}
			.foregroundColor(kind.color)
			.hoverTooltip(kind.help)
		case .dot:
			Circle()
				.fill(kind.color)
				.frame(width: 8, height: 8)
				.overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
				.accessibilityLabel(kind.label)
		}
	}
}

#Preview("Badges") {
	VStack(alignment: .leading, spacing: 12) {
		ForEach(WorkspaceBadgeKind.allCases, id: \.self) { kind in
			HStack(spacing: 16) {
				WorkspaceBadge(kind: kind, size: .label)
				WorkspaceBadge(kind: kind, size: .dot)
			}
		}
	}
	.padding()
}
