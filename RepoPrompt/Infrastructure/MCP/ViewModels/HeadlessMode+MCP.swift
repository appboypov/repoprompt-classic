import Foundation

extension HeadlessMode {
	var mcpModeName: String {
		switch self {
		case .plan:
			return "plan"
		case .review:
			return "review"
		case .chat:
			return "chat"
		}
	}
}
