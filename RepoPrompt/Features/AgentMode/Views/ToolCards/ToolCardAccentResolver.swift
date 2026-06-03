import SwiftUI

internal enum ToolCardAccentResolver {
	static func family(for toolName: String?) -> ClusterToolCategory.ToolFamily {
		guard let normalized = normalizedToolCardName(toolName)?.lowercased() else {
			return .other
		}
		return ClusterToolCategory.classification(forNormalizedToolName: normalized).family
	}

	static func color(for toolName: String?) -> Color {
		switch family(for: toolName) {
		case .navigation:
			return BubbleColors.toolNavigationAccent
		case .edit:
			return BubbleColors.toolEditAccent
		case .execution:
			return BubbleColors.toolExecutionAccent
		case .communication:
			return BubbleColors.toolCommunicationAccent
		case .agentControl:
			return BubbleColors.toolCommunicationAccent
		case .config:
			return BubbleColors.toolConfigAccent
		case .other:
			return BubbleColors.toolOtherAccent
		}
	}
}
