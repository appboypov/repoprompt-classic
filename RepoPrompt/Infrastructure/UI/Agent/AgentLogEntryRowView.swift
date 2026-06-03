import SwiftUI

/// Style variants for log entry rows
enum AgentLogRowStyle {
	case compact   // Smaller, denser (for discovery view)
	case regular   // Standard size (for agent mode)
}

/// A reusable log entry row with consistent icon/color mapping.
struct AgentLogEntryRowView: View {
	let entry: AgentLogEntry
	var style: AgentLogRowStyle = .regular
	
	var body: some View {
		HStack(alignment: .top, spacing: style == .compact ? 6 : 8) {
			Image(systemName: icon)
				.font(style == .compact ? .caption2 : .caption)
				.foregroundColor(color)
				.frame(width: style == .compact ? 12 : 16, alignment: .center)
			
			Text(formattedMessage)
				.font(style == .compact ? .caption : .callout)
				.foregroundColor(color)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
			
			Text(timestamp)
				.font(.caption2)
				.foregroundColor(.secondary.opacity(0.7))
				.monospacedDigit()
				.fixedSize()
		}
		.padding(.vertical, style == .compact ? 0 : 4)
	}
	
	private var formattedMessage: String {
		// Remove "Using tool: " prefix if present
		if entry.message.hasPrefix("Using tool: ") {
			return String(entry.message.dropFirst("Using tool: ".count))
		}
		return entry.message
	}
	
	private var timestamp: String {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter.string(from: entry.timestamp)
	}
	
	private var icon: String {
		switch entry.type {
		case .user: return "person.fill"
		case .assistant: return "cpu"
		case .tool: return "gearshape.fill"
		case .system: return "info.circle"
		case .error: return "exclamationmark.triangle.fill"
		case .thinking: return "brain"
		}
	}
	
	private var color: Color {
		switch entry.type {
		case .user: return .blue
		case .assistant: return .primary
		case .tool: return .orange
		case .system: return .secondary
		case .error: return .red
		case .thinking: return .purple
		}
	}
}
