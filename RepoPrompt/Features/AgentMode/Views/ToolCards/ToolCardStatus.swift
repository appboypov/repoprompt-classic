import SwiftUI

// MARK: - Tool Card Status

/// Status type for tool call/result cards, mapped to semantic meaning rather than emoji parsing
enum ToolCardStatus: Sendable, Equatable {
	case running      // Tool call in progress (spinner)
	case success      // Completed successfully (green)
	case warning      // Partial success or needs attention (yellow)
	case failure      // Failed (red)
	case neutral      // Unknown or informational (gray)

	static func fromTranscriptStatus(_ status: AgentTranscriptToolStatus) -> ToolCardStatus? {
		switch status {
		case .success:
			return .success
		case .warning:
			return .warning
		case .failed, .cancelled:
			return .failure
		case .pending, .running:
			return .neutral
		case .unknown:
			return nil
		}
	}
	
	/// Status color using BubbleColors for consistency
	func color(colorScheme: ColorScheme) -> Color {
		switch self {
		case .running:
			return .secondary
		case .success:
			return BubbleColors.successGreen(colorScheme: colorScheme)
		case .warning:
			return BubbleColors.warningYellow(colorScheme: colorScheme)
		case .failure:
			return BubbleColors.errorRed(colorScheme: colorScheme)
		case .neutral:
			return .secondary
		}
	}
	
	/// SF Symbol name for status
	var iconName: String {
		switch self {
		case .running:
			return "circle.dotted"
		case .success:
			return "checkmark.circle.fill"
		case .warning:
			return "exclamationmark.circle.fill"
		case .failure:
			return "xmark.circle.fill"
		case .neutral:
			return "circle.fill"
		}
	}
}

// MARK: - Status Dot View

/// A small colored dot indicating tool status
struct StatusDot: View {
	let status: ToolCardStatus
	var size: CGFloat = 8
	
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		if status == .running {
			ProgressView()
				.scaleEffect(0.4)
				.frame(width: size, height: size)
		} else {
			Circle()
				.fill(status.color(colorScheme: colorScheme))
				.frame(width: size, height: size)
		}
	}
}

// MARK: - Status Badge View

/// A small badge with status text for additional context
struct StatusBadge: View {
	let text: String
	let status: ToolCardStatus
	
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		Text(text)
			.font(.system(size: 9, weight: .medium))
			.foregroundColor(status.color(colorScheme: colorScheme))
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(status.color(colorScheme: colorScheme).opacity(0.15))
			.cornerRadius(4)
	}
}

// MARK: - Preview

#if DEBUG
struct ToolCardStatus_Previews: PreviewProvider {
	static var previews: some View {
		VStack(spacing: 16) {
			HStack(spacing: 12) {
				ForEach([ToolCardStatus.running, .success, .warning, .failure, .neutral], id: \.self) { status in
					VStack(spacing: 4) {
						StatusDot(status: status)
						Text(String(describing: status))
							.font(.caption2)
					}
				}
			}
			
			HStack(spacing: 8) {
				StatusBadge(text: "Success", status: .success)
				StatusBadge(text: "Partial", status: .warning)
				StatusBadge(text: "Failed", status: .failure)
			}
		}
		.padding()
	}
}
#endif
